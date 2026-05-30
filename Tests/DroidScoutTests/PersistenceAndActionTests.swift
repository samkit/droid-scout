import Foundation
import Testing
@testable import DroidScout

@Test func localStorePersistsCapsAndRedactsDiagnostics() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(root) }
    let support = root.appendingPathComponent("Support", isDirectory: true)
    let logs = root.appendingPathComponent("Logs", isDirectory: true)
    let store = LocalStore(supportURL: support, logsURL: logs)

    #expect(FileManager.default.fileExists(atPath: support.pathString))
    #expect(FileManager.default.fileExists(atPath: logs.pathString))
    #expect(store.loadSettings() == .defaults)
    #expect(store.loadActivities() == [])
    #expect(store.loadArtifacts() == [])
    #expect(store.loadDeviceNames() == [:])

    var settings = AppSettings.defaults
    settings.customADBPath = "/tmp/adb"
    settings.customScrcpyPath = "/tmp/scrcpy"
    settings.watchedProjectPaths = ["/project"]
    settings.notificationMode = .full
    settings.logTarget = .zed
    settings.logRetentionDays = 21
    settings.packagePollingInterval = 30
    settings.confidenceThreshold = .high
    settings.backgroundUpdateChecks = false
    settings.hiddenDeviceIdentities = ["USB1"]
    store.saveSettings(settings)
    #expect(store.loadSettings() == settings)

    let activities = (0..<85).map { index in
        ActivityEvent(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: Double(index)),
            kind: .device,
            title: "event-\(index)",
            detail: "detail-\(index)",
            deviceSerials: ["USB\(index)"],
            success: index.isMultiple(of: 2)
        )
    }
    store.saveActivities(activities)
    let loadedActivities = store.loadActivities()
    #expect(loadedActivities.count == 80)
    #expect(loadedActivities.first?.title == "event-0")
    #expect(loadedActivities.last?.title == "event-79")

    let artifacts = (0..<125).map { index in
        TestSupport.artifact(
            paths: ["/tmp/app-\(index).apk"],
            packageName: "com.example.\(index)",
            devices: ["USB\(index)"],
            perDeviceResults: ["USB\(index)": "Success"]
        )
    }
    store.saveArtifacts(artifacts)
    let loadedArtifacts = store.loadArtifacts()
    #expect(loadedArtifacts.count == 120)
    #expect(loadedArtifacts.first?.packageName == "com.example.0")
    #expect(loadedArtifacts.last?.packageName == "com.example.119")

    store.saveDeviceNames(["USB1": "Pixel"])
    #expect(store.loadDeviceNames() == ["USB1": "Pixel"])

    let diagnosticsURL = try store.exportDiagnostics(
        settings: settings,
        devices: [TestSupport.device(serial: "secret-serial", friendlyName: "Secret Phone")],
        activities: Array(activities.prefix(1)),
        artifacts: [artifacts[0]]
    )
    let diagnosticsText = try String(contentsOf: diagnosticsURL)
    #expect(diagnosticsText.contains(#""serial" : "device-1""#))
    #expect(!diagnosticsText.contains("secret-serial"))
    #expect(!diagnosticsText.contains(#""USB0" : "Success""#))
    #expect(diagnosticsText.contains("redacted-device"))
}

@MainActor
@Test func installCoordinatorRunsRealADBScriptAndReportsStateChanges() async throws {
    let temp = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(temp) }

    let log = temp.appendingPathComponent("adb-calls.txt")
    let adb = temp.appendingPathComponent("adb")
    try TestSupport.executableScript(adb, body: """
    echo "$@" >> "\(log.pathString)"
    if [ "$2" = "fail-device" ]; then
      echo "install failed" >&2
      exit 12
    fi
    echo "install ok"
    exit 0
    """)

    let coordinator = InstallCoordinator(adbClient: ADBClient(adbPath: adb.pathString), concurrencyLimit: 1)
    var updates: [InstallStatus] = []
    coordinator.onResultChanged = { updates.append($0.status) }

    let artifact = TestSupport.artifact(paths: ["/tmp/base.apk", "/tmp/config.apk"], kind: .splitAPK)
    let results = await coordinator.install(artifact: artifact, devices: [
        TestSupport.device(serial: "ok-device", state: .online),
        TestSupport.device(serial: "fail-device", state: .online),
        TestSupport.device(serial: "offline-device", state: .offline)
    ])

    #expect(results.map(\.deviceSerial) == ["ok-device", "fail-device", "offline-device"])
    #expect(results.map(\.status) == [.success, .failed, .skipped])
    #expect(results[0].stdout == "install ok\n")
    #expect(results[1].stderr == "install failed\n")
    #expect(results[2].stderr == "Device is offline")
    #expect(updates.contains(.queued))
    #expect(updates.contains(.installing))
    #expect(updates.contains(.success))
    #expect(updates.contains(.failed))
    #expect(updates.contains(.skipped))

    let calls = try String(contentsOf: log)
    #expect(calls.contains("-s ok-device install-multiple -r /tmp/base.apk /tmp/config.apk"))
    #expect(calls.contains("-s fail-device install-multiple -r /tmp/base.apk /tmp/config.apk"))
}

@MainActor
@Test func logSessionManagerStartsStopsAndPrunesRealLogFilesWithoutOpeningApps() async throws {
    let temp = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(temp) }
    let logs = temp.appendingPathComponent("Logs", isDirectory: true)

    var opened: [(URL, LogTarget)] = []
    let manager = LogSessionManager(logsURL: logs) { url, target in
        opened.append((url, target))
    }

    let session = try manager.startLogStream(
        device: TestSupport.device(serial: "USB/1:2", friendlyName: "Pixel"),
        adbPath: "/bin/echo",
        target: .defaultApp
    )
    #expect(manager.sessions == [session])
    #expect(opened.count == 1)
    #expect(opened.first?.1 == .defaultApp)
    #expect(session.fileURL.lastPathComponent.hasPrefix("USB_1_2-"))

    let didWriteLog = await waitForFile(session.fileURL, toContain: "-s USB/1:2 logcat", timeout: 2)
    manager.stop(session)
    #expect(manager.sessions.isEmpty)
    let logText = try String(contentsOf: session.fileURL)
    #expect(didWriteLog)
    #expect(logText.contains("-s USB/1:2 logcat"))

    let oldLog = logs.appendingPathComponent("old.log")
    let freshLog = logs.appendingPathComponent("fresh.log")
    try TestSupport.touch(oldLog, modifiedAt: Date().addingTimeInterval(-10 * 24 * 60 * 60))
    try TestSupport.touch(freshLog, modifiedAt: Date())
    manager.pruneLogs(retentionDays: 7)
    #expect(!FileManager.default.fileExists(atPath: oldLog.pathString))
    #expect(FileManager.default.fileExists(atPath: freshLog.pathString))
    manager.pruneLogs(retentionDays: 0)
    #expect(FileManager.default.fileExists(atPath: freshLog.pathString))
}

@MainActor
private func waitForFile(_ url: URL, toContain text: String, timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if (try? String(contentsOf: url))?.contains(text) == true {
            return true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return (try? String(contentsOf: url))?.contains(text) == true
}

@Test func notificationGateFiltersModesAndDuplicateKeys() {
    var gate = NotificationGate()
    let now = Date(timeIntervalSince1970: 1_000)
    let offInstall = gate.shouldNotify(kind: .install, mode: .off, key: "install", now: now)
    let reducedDevice = gate.shouldNotify(kind: .device, mode: .reduced, key: "device", now: now)
    let firstInstall = gate.shouldNotify(kind: .install, mode: .reduced, key: "install", now: now)
    let duplicateInstall = gate.shouldNotify(kind: .install, mode: .reduced, key: "install", now: now.addingTimeInterval(30))
    let expiredInstall = gate.shouldNotify(kind: .install, mode: .reduced, key: "install", now: now.addingTimeInterval(61))
    let fullDevice = gate.shouldNotify(kind: .device, mode: .full, key: "device", now: now)
    let fullDeploy = gate.shouldNotify(kind: .deploy, mode: .full, key: "deploy", now: now)
    let reducedUpdate = gate.shouldNotify(kind: .update, mode: .reduced, key: "update", now: now)
    let reducedADB = gate.shouldNotify(kind: .adb, mode: .reduced, key: "adb", now: now)
    let reducedLog = gate.shouldNotify(kind: .log, mode: .reduced, key: "log", now: now)

    #expect(!offInstall)
    #expect(!reducedDevice)
    #expect(firstInstall)
    #expect(!duplicateInstall)
    #expect(expiredInstall)
    #expect(fullDevice)
    #expect(fullDeploy)
    #expect(reducedUpdate)
    #expect(reducedADB)
    #expect(reducedLog)
}
