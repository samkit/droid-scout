import Foundation

@MainActor
final class InstallCoordinator {
    private let adbClient: ADBClient
    private let concurrencyLimit: Int
    var onResultChanged: ((InstallResult) -> Void)?

    init(adbClient: ADBClient, concurrencyLimit: Int = 3) {
        self.adbClient = adbClient
        self.concurrencyLimit = concurrencyLimit
    }

    func install(artifact: ArtifactRecord, devices: [AndroidDevice]) async -> [InstallResult] {
        var results = devices.map { device in
            InstallResult(
                id: UUID(),
                deviceSerial: device.serial,
                artifactID: artifact.id,
                artifactName: artifact.displayName,
                artifactPath: artifact.primaryPath,
                status: device.state == .online ? .queued : .skipped,
                stdout: "",
                stderr: device.state == .online ? "" : "Device is \(device.state.displayName)",
                startedAt: Date(),
                completedAt: device.state == .online ? nil : Date()
            )
        }

        for result in results {
            onResultChanged?(result)
        }

        let onlineIndexes = results.indices.filter { results[$0].status == .queued }
        var cursor = onlineIndexes.startIndex
        while cursor < onlineIndexes.endIndex {
            let batchIndexes = Array(onlineIndexes[cursor..<min(cursor + concurrencyLimit, onlineIndexes.endIndex)])
            await withTaskGroup(of: (Int, InstallResult).self) { group in
                for index in batchIndexes {
                    var installing = results[index]
                    installing.status = .installing
                    onResultChanged?(installing)
                    results[index] = installing

                    group.addTask { [adbPath = adbClient.adbPath, artifact] in
                        let deviceSerial = installing.deviceSerial
                        let command = Self.installArguments(for: artifact)
                        let result = await ProcessRunner.run(
                            executablePath: adbPath,
                            arguments: ["-s", deviceSerial] + command,
                            timeout: 180
                        )
                        var completed = installing
                        completed.status = result.succeeded ? .success : .failed
                        completed.stdout = result.stdout
                        completed.stderr = result.stderr
                        completed.completedAt = Date()
                        return (index, completed)
                    }
                }

                for await (index, completed) in group {
                    results[index] = completed
                    onResultChanged?(completed)
                }
            }
            cursor += concurrencyLimit
        }

        return results
    }

    private nonisolated static func installArguments(for artifact: ArtifactRecord) -> [String] {
        if artifact.kind == .splitAPK || artifact.paths.count > 1 {
            return ["install-multiple", "-r"] + artifact.paths
        }
        return ["install", "-r", artifact.paths.first ?? ""]
    }
}

@MainActor
final class LogSessionManager {
    struct Session: Identifiable, Hashable {
        var id: UUID
        var deviceSerial: String
        var fileURL: URL
        var startedAt: Date
    }

    private let fileManager: FileManager
    private let logsURL: URL
    private let openLogHandler: @MainActor (URL, LogTarget) -> Void
    private let revealLogsHandler: @MainActor (URL) -> Void
    private var processes: [UUID: Process] = [:]
    private var fileHandles: [UUID: FileHandle] = [:]
    private(set) var sessions: [Session] = []

    init(
        fileManager: FileManager = .default,
        logsURL: URL = AppConstants.logsURL,
        openLogHandler: @escaping @MainActor (URL, LogTarget) -> Void = { _, _ in },
        revealLogsHandler: @escaping @MainActor (URL) -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        self.logsURL = logsURL
        self.openLogHandler = openLogHandler
        self.revealLogsHandler = revealLogsHandler
    }

    func startLogStream(device: AndroidDevice, adbPath: String, target: LogTarget) throws -> Session {
        try fileManager.createDirectory(at: logsURL, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safeSerial = device.serial.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let fileURL = logsURL.appendingPathComponent("\(safeSerial)-\(timestamp).log")
        fileManager.createFile(atPath: fileURL.pathString, contents: nil)

        let handle = try FileHandle(forWritingTo: fileURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", device.serial, "logcat"]
        process.standardOutput = handle
        process.standardError = handle
        try process.run()

        let session = Session(id: UUID(), deviceSerial: device.serial, fileURL: fileURL, startedAt: Date())
        processes[session.id] = process
        fileHandles[session.id] = handle
        sessions.append(session)
        openLogHandler(fileURL, target)
        return session
    }

    func stop(_ session: Session) {
        if let process = processes[session.id], process.isRunning {
            process.terminate()
        }
        processes[session.id] = nil
        try? fileHandles[session.id]?.close()
        fileHandles[session.id] = nil
        sessions.removeAll { $0.id == session.id }
    }

    func stopAll() {
        for session in sessions {
            stop(session)
        }
    }

    func revealLogsFolder() {
        try? fileManager.createDirectory(at: logsURL, withIntermediateDirectories: true)
        revealLogsHandler(logsURL)
    }

    func pruneLogs(retentionDays: Int) {
        guard retentionDays > 0,
              let files = try? fileManager.contentsOfDirectory(
                at: logsURL,
                includingPropertiesForKeys: [.contentModificationDateKey]
              )
        else { return }

        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            if modified < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }

}

@MainActor
final class AppNotificationManager {
    private var gate = NotificationGate()
    private let requestAuthorizationHandler: @MainActor () -> Void
    private let deliverNotification: @MainActor (_ title: String, _ body: String) -> Void

    init(
        requestAuthorizationHandler: @escaping @MainActor () -> Void = {},
        deliverNotification: @escaping @MainActor (_ title: String, _ body: String) -> Void = { _, _ in }
    ) {
        self.requestAuthorizationHandler = requestAuthorizationHandler
        self.deliverNotification = deliverNotification
    }

    func requestAuthorization() {
        requestAuthorizationHandler()
    }

    func notify(kind: ActivityKind, title: String, body: String, mode: NotificationMode, key: String) {
        guard gate.shouldNotify(kind: kind, mode: mode, key: key) else { return }
        deliverNotification(title, body)
    }
}

struct NotificationGate {
    private var recentKeys: [String: Date] = [:]

    mutating func shouldNotify(kind: ActivityKind, mode: NotificationMode, key: String, now: Date = Date()) -> Bool {
        guard mode != .off else { return false }
        if let date = recentKeys[key], now.timeIntervalSince(date) < 60 {
            return false
        }

        if mode == .reduced {
            switch kind {
            case .device:
                return false
            case .install, .deploy, .update, .adb, .log:
                recentKeys[key] = now
                return true
            }
        }

        recentKeys[key] = now
        return true
    }
}

@MainActor
final class UpdateService {
    private let openHandler: @MainActor (URL) -> Void

    init(openHandler: @escaping @MainActor (URL) -> Void = { _ in }) {
        self.openHandler = openHandler
    }

    func checkForUpdates() {
        openHandler(AppConstants.githubReleasesURL)
    }
}

@MainActor
final class ScreenRecordManager {
    struct Session: Identifiable, Hashable, Sendable {
        var id: UUID
        var deviceSerial: String
        var localURL: URL
        var remotePath: String
        var startedAt: Date
    }

    private var processes: [UUID: Process] = [:]
    private(set) var sessions: [Session] = []

    func startRecording(device: AndroidDevice, adbPath: String, localURL: URL) throws -> Session {
        let remotePath = "/sdcard/droid_scout_record_\(UUID().uuidString.prefix(8)).mp4"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", device.serial, "shell", "screenrecord", remotePath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let session = Session(id: UUID(), deviceSerial: device.serial, localURL: localURL, remotePath: remotePath, startedAt: Date())
        processes[session.id] = process
        sessions.append(session)
        return session
    }

    func stop(_ session: Session, adbPath: String) async -> CommandResult {
        if let process = processes[session.id] {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        processes[session.id] = nil
        sessions.removeAll { $0.id == session.id }

        try? await Task.sleep(nanoseconds: 800_000_000)

        let pullResult = await ProcessRunner.run(
            executablePath: adbPath,
            arguments: ["-s", session.deviceSerial, "pull", session.remotePath, session.localURL.pathString],
            timeout: 60
        )

        _ = await ProcessRunner.run(
            executablePath: adbPath,
            arguments: ["-s", session.deviceSerial, "shell", "rm", session.remotePath],
            timeout: 10
        )

        return pullResult
    }

    func discard(_ session: Session, adbPath: String) async {
        if let process = processes[session.id] {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        processes[session.id] = nil
        sessions.removeAll { $0.id == session.id }

        try? await Task.sleep(nanoseconds: 300_000_000)

        _ = await ProcessRunner.run(
            executablePath: adbPath,
            arguments: ["-s", session.deviceSerial, "shell", "rm", session.remotePath],
            timeout: 10
        )
    }
}
