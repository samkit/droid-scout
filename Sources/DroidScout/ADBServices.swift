import Foundation

final class ADBLocator: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func locate(customPath: String?) async -> ADBAvailability {
        let candidates = adbCandidates(customPath: customPath)
        for candidate in candidates {
            guard isExecutable(candidate) else { continue }
            let result = await ProcessRunner.run(executablePath: candidate, arguments: ["version"], timeout: 5)
            if result.succeeded {
                return .healthy(path: candidate, version: firstLine(result.stdout) ?? "ADB available")
            }
            if customPath == candidate {
                return .failed(path: candidate, message: result.stderr.nilIfBlank ?? result.stdout.nilIfBlank ?? "The configured ADB path could not be validated.")
            }
        }

        return .missing(message: "Choose ADB manually or install it with: brew install android-platform-tools")
    }

    private func adbCandidates(customPath: String?) -> [String] {
        var candidates: [String] = []
        if let customPath = customPath?.nilIfBlank {
            candidates.append(expandTilde(customPath))
        }

        let environment = ProcessInfo.processInfo.environment
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = environment[key]?.nilIfBlank {
                candidates.append(URL(fileURLWithPath: expandTilde(root))
                    .appendingPathComponent("platform-tools/adb")
                    .pathString)
            }
        }

        candidates.append(URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Android/sdk/platform-tools/adb")
            .pathString)
        candidates.append("/opt/homebrew/bin/adb")
        candidates.append("/usr/local/bin/adb")

        let pathValue = environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for directory in pathValue.split(separator: ":") {
            candidates.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("adb").pathString)
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private func isExecutable(_ path: String) -> Bool {
        fileManager.isExecutableFile(atPath: path)
    }

    private func firstLine(_ text: String) -> String? {
        text.split(separator: "\n").first.map(String.init)
    }

    private func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

final class ADBClient: @unchecked Sendable {
    let adbPath: String

    init(adbPath: String) {
        self.adbPath = adbPath
    }

    func run(arguments: [String], timeout: TimeInterval = 30) async -> CommandResult {
        await ProcessRunner.run(executablePath: adbPath, arguments: arguments, timeout: timeout)
    }

    func run(serial: String, arguments: [String], timeout: TimeInterval = 30) async -> CommandResult {
        await run(arguments: ["-s", serial] + arguments, timeout: timeout)
    }

    func listDevices() async -> [DeviceSnapshot] {
        let result = await run(arguments: ["devices", "-l"], timeout: 8)
        guard result.succeeded else { return [] }
        return ADBDeviceParser.parseDevices(result.stdout)
    }

    func pair(address: String, pairingCode: String) async -> CommandResult {
        await run(arguments: ["pair", address, pairingCode], timeout: 20)
    }

    func mdnsServices() async -> CommandResult {
        await run(arguments: ["mdns", "services"], timeout: 10)
    }

    func takeScreenshot(serial: String, localURL: URL) async -> CommandResult {
        let remotePath = "/sdcard/droid_scout_screenshot.png"
        let capResult = await run(serial: serial, arguments: ["shell", "screencap", "-p", remotePath], timeout: 15)
        guard capResult.succeeded else { return capResult }
        let pullResult = await run(serial: serial, arguments: ["pull", remotePath, localURL.pathString], timeout: 30)
        _ = await run(serial: serial, arguments: ["shell", "rm", remotePath], timeout: 10)
        return pullResult
    }

    func clearAppData(serial: String, packageId: String) async -> CommandResult {
        await run(serial: serial, arguments: ["shell", "pm", "clear", packageId], timeout: 15)
    }

    func uninstallApp(serial: String, packageId: String) async -> CommandResult {
        await run(serial: serial, arguments: ["shell", "pm", "uninstall", packageId], timeout: 15)
    }

    func reboot(serial: String, mode: String?) async -> CommandResult {
        let args = mode == nil || mode!.isEmpty ? ["reboot"] : ["reboot", mode!]
        return await run(serial: serial, arguments: args, timeout: 15)
    }

    func forwardPort(serial: String, local: String, remote: String) async -> CommandResult {
        await run(serial: serial, arguments: ["forward", local, remote], timeout: 15)
    }

    func removeForwardPort(serial: String, local: String) async -> CommandResult {
        await run(serial: serial, arguments: ["forward", "--remove", local], timeout: 15)
    }

    func reversePort(serial: String, remote: String, local: String) async -> CommandResult {
        await run(serial: serial, arguments: ["reverse", remote, local], timeout: 15)
    }

    func removeReversePort(serial: String, remote: String) async -> CommandResult {
        await run(serial: serial, arguments: ["reverse", "--remove", remote], timeout: 15)
    }
}

final class EmulatorService: @unchecked Sendable {
    private let fileManager: FileManager
    private let emulatorPath: String?

    init(adbPath: String, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        emulatorPath = Self.locateEmulator(adbPath: adbPath, fileManager: fileManager)
    }

    var isAvailable: Bool {
        emulatorPath != nil
    }

    func listAVDs() async -> [String] {
        guard let emulatorPath else { return [] }
        let result = await ProcessRunner.run(executablePath: emulatorPath, arguments: ["-list-avds"], timeout: 8)
        guard result.succeeded else { return [] }
        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func startAVD(named name: String) throws {
        guard let emulatorPath else {
            throw EmulatorServiceError.emulatorNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: emulatorPath)
        process.arguments = ["-avd", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func locateEmulator(adbPath: String, fileManager: FileManager) -> String? {
        let candidates = emulatorCandidates(adbPath: adbPath)
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    private static func emulatorCandidates(adbPath: String) -> [String] {
        var candidates: [String] = []
        let adbURL = URL(fileURLWithPath: adbPath)
        if adbURL.deletingLastPathComponent().lastPathComponent == "platform-tools" {
            candidates.append(adbURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("emulator/emulator")
                .pathString)
        }

        let environment = ProcessInfo.processInfo.environment
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = environment[key]?.nilIfBlank {
                candidates.append(URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
                    .appendingPathComponent("emulator/emulator")
                    .pathString)
            }
        }

        candidates.append(URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Android/sdk/emulator/emulator")
            .pathString)
        candidates.append("/opt/homebrew/bin/emulator")
        candidates.append("/usr/local/bin/emulator")

        let pathValue = environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for directory in pathValue.split(separator: ":") {
            candidates.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("emulator").pathString)
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }
}

enum EmulatorServiceError: LocalizedError {
    case emulatorNotFound

    var errorDescription: String? {
        switch self {
        case .emulatorNotFound:
            "The Android Emulator tool was not found in the detected SDK."
        }
    }
}

enum ADBDeviceParser {
    static func parseDevices(_ output: String) -> [DeviceSnapshot] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .dropFirst()
            .compactMap { line in
                let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard tokens.count >= 2 else { return nil }

                let serial = tokens[0]
                let state = DeviceConnectionState(adbState: tokens[1])
                let attributes = Dictionary(uniqueKeysWithValues: tokens.dropFirst(2).compactMap { token -> (String, String)? in
                    let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { return nil }
                    return (parts[0], parts[1])
                })

                let modelHint = attributes["model"]?.replacingOccurrences(of: "_", with: " ")
                let usbHint = attributes["usb"].map { _ in "USB" }
                let transportHint = serial.contains(":") ? "Wi-Fi" : usbHint

                return DeviceSnapshot(
                    serial: serial,
                    state: state,
                    modelHint: modelHint,
                    transportHint: transportHint
                )
            }
    }
}

/// Parses output from `adb mdns services`.
/// Used by the QR pairing flow to discover the real IP:port advertised by the phone after it scans our QR.
enum ADBMdnsParser {
    struct Service: Equatable {
        let name: String
        let type: String
        let address: String?
    }

    static func parseMdnsServices(_ output: String) -> [Service] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .dropFirst() // skip "List of discovered mdns services"
            .compactMap { line -> Service? in
                let tokens = line.split(separator: " ").map(String.init).filter { !$0.isEmpty }
                guard tokens.count >= 3 else { return nil }

                let name = tokens[0]
                let type = tokens[1]
                let address = tokens.last

                // Only interested in pairing services for the QR flow; still return others for test completeness.
                return Service(name: name, type: type, address: address)
            }
    }
}

final class DeviceInfoService: @unchecked Sendable {
    private let adbClient: ADBClient

    init(adbClient: ADBClient) {
        self.adbClient = adbClient
    }

    func hydrate(_ snapshots: [DeviceSnapshot], cachedNames: [String: String]) async -> [AndroidDevice] {
        var devices: [AndroidDevice] = []
        for snapshot in snapshots {
            if snapshot.state == .online {
                let props = await properties(serial: snapshot.serial)
                var avdName = avdNameFromProperties(props)
                if avdName == nil {
                    avdName = await runningAVDName(for: snapshot)
                }
                if avdName == nil {
                    avdName = await runningAVDNameFromGetprop(serial: snapshot.serial)
                }
                let manufacturer = bestProperty(["ro.product.manufacturer", "ro.product.vendor.manufacturer"], in: props)
                let model = bestProperty([
                    "ro.product.marketname",
                    "ro.product.vendor.marketname",
                    "ro.product.odm.marketname",
                    "ro.product.system.marketname",
                    "ro.product.product.marketname",
                    "ro.config.marketing_name",
                    "ro.product.model",
                    "ro.product.vendor.model"
                ], in: props)
                let release = props["ro.build.version.release"]?.nilIfBlank
                let api = props["ro.build.version.sdk"]?.nilIfBlank
                let fallback = snapshot.modelHint ?? cachedNames[snapshot.serial] ?? snapshot.serial
                let friendlyName = avdName ?? friendlyName(model: model, manufacturer: manufacturer, fallback: fallback)
                devices.append(AndroidDevice(
                    serial: snapshot.serial,
                    state: snapshot.state,
                    friendlyName: friendlyName,
                    androidVersion: release,
                    apiLevel: api,
                    transportHint: snapshot.transportHint,
                    lastSeen: Date(),
                    avdName: avdName
                ))
            } else {
                let avdName = await runningAVDName(for: snapshot)
                devices.append(AndroidDevice(
                    serial: snapshot.serial,
                    state: snapshot.state,
                    friendlyName: cachedNames[snapshot.serial] ?? snapshot.modelHint ?? "Android device",
                    androidVersion: nil,
                    apiLevel: nil,
                    transportHint: snapshot.transportHint,
                    lastSeen: Date(),
                    avdName: avdName
                ))
            }
        }
        return sortDevices(devices)
    }

    private func runningAVDName(for snapshot: DeviceSnapshot) async -> String? {
        guard snapshot.serial.hasPrefix("emulator-") else { return nil }
        let result = await adbClient.run(serial: snapshot.serial, arguments: ["emu", "avd", "name"], timeout: 3)
        guard result.succeeded else { return nil }
        return result.stdout
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != "OK" }
    }

    private func runningAVDNameFromGetprop(serial: String) async -> String? {
        guard serial.hasPrefix("emulator-") else { return nil }
        for key in ["ro.boot.qemu.avd_name", "ro.kernel.qemu.avd_name"] {
            let result = await adbClient.run(serial: serial, arguments: ["shell", "getprop", key], timeout: 3)
            guard result.succeeded else { continue }
            if let value = result.stdout.nilIfBlank {
                return value
            }
        }
        return nil
    }

    private func avdNameFromProperties(_ properties: [String: String]) -> String? {
        bestProperty(["ro.boot.qemu.avd_name", "ro.kernel.qemu.avd_name"], in: properties)
    }

    private func properties(serial: String) async -> [String: String] {
        let result = await adbClient.run(serial: serial, arguments: ["shell", "getprop"], timeout: 8)
        guard result.succeeded else { return [:] }
        var values: [String: String] = [:]
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: "]", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { continue }
            let key = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ":[] "))
            if !key.isEmpty, !value.isEmpty {
                values[key] = value.replacingOccurrences(of: "_", with: " ")
            }
        }
        return values
    }

    private func bestProperty(_ keys: [String], in properties: [String: String]) -> String? {
        keys.compactMap { properties[$0]?.nilIfBlank }.first
    }

    private func friendlyName(model: String?, manufacturer: String?, fallback: String) -> String {
        guard var model = model?.nilIfBlank else { return fallback }
        let maker = manufacturer.flatMap(canonicalManufacturer)

        if maker == "Samsung", let marketingName = SamsungMarketingNames.name(for: model) {
            model = marketingName
        }

        guard let maker else { return model }
        if model.localizedCaseInsensitiveContains(maker) {
            return model
        }
        return "\(maker) \(model)"
    }

    private func sortDevices(_ devices: [AndroidDevice]) -> [AndroidDevice] {
        devices.sorted {
            if stateRank($0.state) != stateRank($1.state) {
                return stateRank($0.state) < stateRank($1.state)
            }
            return $0.friendlyName.localizedCaseInsensitiveCompare($1.friendlyName) == .orderedAscending
        }
    }

    private func stateRank(_ state: DeviceConnectionState) -> Int {
        switch state {
        case .online: 0
        case .unauthorized: 1
        case .offline: 2
        case .stopped: 3
        case .unknown: 4
        }
    }

    private func canonicalManufacturer(_ manufacturer: String) -> String? {
        let normalized = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        switch normalized.lowercased() {
        case "samsung": return "Samsung"
        case "google": return "Google"
        case "oneplus": return "OnePlus"
        case "xiaomi": return "Xiaomi"
        case "motorola": return "Motorola"
        case "sony": return "Sony"
        case "huawei": return "Huawei"
        case "oppo": return "OPPO"
        case "vivo": return "vivo"
        case "realme": return "realme"
        case "nothing": return "Nothing"
        default: return normalized.capitalized
        }
    }
}

private enum SamsungMarketingNames {
    static func name(for model: String) -> String? {
        let normalized = model.uppercased().replacingOccurrences(of: " ", with: "")
        let knownPrefixes: [(String, String)] = [
            ("SM-S928", "Galaxy S24 Ultra"),
            ("SM-S926", "Galaxy S24+"),
            ("SM-S921", "Galaxy S24"),
            ("SM-S918", "Galaxy S23 Ultra"),
            ("SM-S916", "Galaxy S23+"),
            ("SM-S911", "Galaxy S23"),
            ("SM-S711", "Galaxy S23 FE"),
            ("SM-S908", "Galaxy S22 Ultra"),
            ("SM-S906", "Galaxy S22+"),
            ("SM-S901", "Galaxy S22"),
            ("SM-G998", "Galaxy S21 Ultra"),
            ("SM-G996", "Galaxy S21+"),
            ("SM-G991", "Galaxy S21"),
            ("SM-G988", "Galaxy S20 Ultra"),
            ("SM-G986", "Galaxy S20+"),
            ("SM-G981", "Galaxy S20"),
            ("SM-F956", "Galaxy Z Fold6"),
            ("SM-F946", "Galaxy Z Fold5"),
            ("SM-F936", "Galaxy Z Fold4"),
            ("SM-F926", "Galaxy Z Fold3"),
            ("SM-F741", "Galaxy Z Flip6"),
            ("SM-F731", "Galaxy Z Flip5"),
            ("SM-F721", "Galaxy Z Flip4"),
            ("SM-F711", "Galaxy Z Flip3")
        ]
        return knownPrefixes.first { normalized.hasPrefix($0.0) }?.1
    }
}

@MainActor
final class DeviceTracker {
    enum WatcherState: Equatable {
        case stopped
        case running
        case failed(String)
    }

    private(set) var watcherState: WatcherState = .stopped
    private var trackingProcess: Process?
    private var pollingTask: Task<Void, Never>?
    private var adbClient: ADBClient?
    private var infoService: DeviceInfoService?
    private var emulatorService: EmulatorService?
    private var cachedNames: [String: String] = [:]
    var onDevicesChanged: (([AndroidDevice]) -> Void)?
    var onWatcherError: ((String) -> Void)?

    func start(adbClient: ADBClient, emulatorService: EmulatorService?, cachedNames: [String: String], interval: TimeInterval) {
        stop()
        self.adbClient = adbClient
        self.infoService = DeviceInfoService(adbClient: adbClient)
        self.emulatorService = emulatorService
        self.cachedNames = cachedNames
        launchTrackDevices(adbPath: adbClient.adbPath)
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                self.ensureWatcher()
                let seconds = UInt64(max(interval, 3) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: seconds)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        if let trackingProcess, trackingProcess.isRunning {
            trackingProcess.terminate()
        }
        trackingProcess = nil
        emulatorService = nil
        watcherState = .stopped
    }

    func refresh() async {
        guard let adbClient, let infoService else { return }
        let snapshots = await adbClient.listDevices()
        let devices = await infoService.hydrate(snapshots, cachedNames: cachedNames)
        let avdNames = await emulatorService?.listAVDs() ?? []
        onDevicesChanged?(AVDDeviceMerger.mergeAVDs(avdNames, into: devices))
    }

    func updateCachedNames(_ names: [String: String]) {
        cachedNames = names
    }

    private func ensureWatcher() {
        guard let adbClient else { return }
        if trackingProcess?.isRunning != true {
            launchTrackDevices(adbPath: adbClient.adbPath)
        }
    }

    private func launchTrackDevices(adbPath: String) {
        if let trackingProcess, trackingProcess.isRunning {
            trackingProcess.terminate()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["track-devices"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            trackingProcess = process
            watcherState = .running
        } catch {
            trackingProcess = nil
            watcherState = .failed(error.localizedDescription)
            onWatcherError?(error.localizedDescription)
        }
    }

}

enum AVDDeviceMerger {
    static func mergeAVDs(_ avdNames: [String], into devices: [AndroidDevice]) -> [AndroidDevice] {
        let devices = devices.map { device in
            guard device.avdName == nil,
                  device.serial.hasPrefix("emulator-"),
                  let matchingAVDName = avdNames.first(where: { avdNameMatches($0, device.friendlyName) })
            else { return device }

            var device = device
            device.avdName = matchingAVDName
            device.friendlyName = matchingAVDName
            return device
        }
        let runningAVDs = devices.compactMap(\.avdName).map(normalizedAVDName)
        let stopped = avdNames
            .filter { avdName in
                !runningAVDs.contains { normalizedNamesMatch($0, normalizedAVDName(avdName)) }
            }
            .map { avdName in
                AndroidDevice(
                    serial: "avd:\(avdName)",
                    state: .stopped,
                    friendlyName: avdName,
                    androidVersion: nil,
                    apiLevel: nil,
                    transportHint: "Emulator",
                    lastSeen: Date(),
                    avdName: avdName
                )
            }

        return deduplicateEmulators(devices + stopped).sorted {
            if stateRank($0.state) != stateRank($1.state) {
                return stateRank($0.state) < stateRank($1.state)
            }
            return $0.friendlyName.localizedCaseInsensitiveCompare($1.friendlyName) == .orderedAscending
        }
    }

    private static func stateRank(_ state: DeviceConnectionState) -> Int {
        switch state {
        case .online: 0
        case .unauthorized: 1
        case .offline: 2
        case .stopped: 3
        case .unknown: 4
        }
    }

    private static func avdNameMatches(_ lhs: String, _ rhs: String) -> Bool {
        normalizedNamesMatch(normalizedAVDName(lhs), normalizedAVDName(rhs))
    }

    private static func normalizedAVDName(_ name: String) -> String {
        name
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
            .map(String.init)
            .joined()
    }

    private static func normalizedNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs {
            return true
        }

        let shorter = lhs.count <= rhs.count ? lhs : rhs
        let longer = lhs.count > rhs.count ? lhs : rhs
        return shorter.count >= 8 && longer.hasPrefix(shorter)
    }

    private static func deduplicateEmulators(_ devices: [AndroidDevice]) -> [AndroidDevice] {
        var devicesByKey: [String: AndroidDevice] = [:]
        var passthrough: [AndroidDevice] = []

        for device in devices {
            guard device.isEmulator else {
                passthrough.append(device)
                continue
            }

            let keySource = device.avdName ?? device.friendlyName
            let key = normalizedAVDName(keySource)
            guard !key.isEmpty else {
                passthrough.append(device)
                continue
            }

            if let existingKey = devicesByKey.keys.first(where: { normalizedNamesMatch($0, key) }),
               let existing = devicesByKey[existingKey] {
                devicesByKey[existingKey] = preferredEmulator(existing, device)
            } else {
                devicesByKey[key] = device
            }
        }

        return passthrough + devicesByKey.values
    }

    private static func preferredEmulator(_ lhs: AndroidDevice, _ rhs: AndroidDevice) -> AndroidDevice {
        if lhs.state == .stopped, rhs.state != .stopped {
            return rhs
        }
        if rhs.state == .stopped, lhs.state != .stopped {
            return lhs
        }
        if lhs.avdName == nil, rhs.avdName != nil {
            return rhs
        }
        return lhs
    }
}

public final class ScrcpyLocator: @unchecked Sendable {
    public nonisolated(unsafe) static var customPath: String?
    
    public static func locate(customPath: String? = nil, fileManager: FileManager = .default) -> String? {
        let pathToCheck = customPath ?? Self.customPath
        if let pathToCheck {
            return fileManager.isExecutableFile(atPath: pathToCheck) ? pathToCheck : nil
        }
        let candidates = [
            "/opt/homebrew/bin/scrcpy",
            "/usr/local/bin/scrcpy",
            "/usr/bin/scrcpy"
        ]
        for candidate in candidates {
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        
        let environment = ProcessInfo.processInfo.environment
        let pathValue = environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for directory in pathValue.split(separator: ":") {
            let path = URL(fileURLWithPath: String(directory)).appendingPathComponent("scrcpy").pathString
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}
