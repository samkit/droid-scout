import Foundation
import Testing
@testable import DroidScout

private struct RealDeviceConfig {
    var adbPath: String
    var serial: String
}

private enum RealDeviceTestError: LocalizedError {
    case missingADBPath
    case missingSerial
    case deviceNotOnline(String)
    case deviceNotListed(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingADBPath:
            "Set DROID_SCOUT_TEST_ADB_PATH or ensure adb is discoverable before enabling real-device tests."
        case .missingSerial:
            "Set DROID_SCOUT_TEST_DEVICE_SERIAL before enabling real-device tests."
        case let .deviceNotOnline(serial):
            "The selected real-device serial is not online: \(serial)"
        case let .deviceNotListed(serial):
            "The selected real-device serial was not present in adb devices: \(serial)"
        case let .commandFailed(message):
            message
        }
    }
}

@MainActor
@Test func realDeviceADBServicesHydrateOnlineDeviceAndReadPackageState() async throws {
    guard let config = try realDeviceConfigIfEnabled() else { return }

    let availability = await ADBLocator().locate(customPath: config.adbPath)
    guard case let .healthy(adbPath, version) = availability else {
        Issue.record("Expected configured adb path to be healthy, got \(availability)")
        return
    }
    #expect(adbPath == config.adbPath)
    #expect(!version.isEmpty)

    let client = ADBClient(adbPath: adbPath)
    let snapshots = await client.listDevices()
    guard let snapshot = snapshots.first(where: { $0.serial == config.serial }) else {
        throw RealDeviceTestError.deviceNotListed(config.serial)
    }
    guard snapshot.state == .online else {
        throw RealDeviceTestError.deviceNotOnline(config.serial)
    }

    let devices = await DeviceInfoService(adbClient: client).hydrate([snapshot], cachedNames: [:])
    guard let device = devices.first(where: { $0.serial == config.serial }) else {
        Issue.record("Expected hydrated device for \(config.serial)")
        return
    }
    #expect(device.state == .online)
    #expect(!device.friendlyName.isEmpty)
    #expect(device.androidVersion?.nilIfBlank != nil)
    #expect(device.apiLevel?.nilIfBlank != nil)

    let snapshotsForAndroid = await PackageStatePoller(adbClient: client).snapshots(
        for: ["android"],
        devices: [device]
    )
    #expect(snapshotsForAndroid.count == 1)
    #expect(snapshotsForAndroid.first?.deviceSerial == config.serial)
    #expect(snapshotsForAndroid.first?.packageName == "android")
}

@MainActor
@Test func realDeviceTrackerAndModelRefreshFromADB() async throws {
    guard let config = try realDeviceConfigIfEnabled() else { return }

    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(root) }

    let store = LocalStore(
        supportURL: root.appendingPathComponent("Support", isDirectory: true),
        logsURL: root.appendingPathComponent("Logs", isDirectory: true)
    )
    let model = DroidScoutModel(store: store)
    model.settings.customADBPath = config.adbPath
    model.settings.notificationMode = .off
    model.settings.packagePollingInterval = 60

    await model.detectADB()
    #expect(model.adbStatus.isHealthy)

    model.refreshDevices()
    let foundDevice = await waitForRealDevice(timeout: 20) {
        model.devices.contains { $0.serial == config.serial && $0.state == .online }
    }
    #expect(foundDevice)
    #expect(model.selectedOnlineDevices.contains { $0.serial == config.serial })
    #expect(model.statusBanner == nil)

    let failingADB = root.appendingPathComponent("failing-adb")
    try TestSupport.executableScript(failingADB, body: "echo failing-adb >&2; exit 4")
    model.settings.customADBPath = failingADB.pathString
    await model.detectADB()
    #expect(!model.adbStatus.isHealthy)
}

@MainActor
@Test func realDeviceLogSessionStartsAndStopsAgainstADB() async throws {
    guard let config = try realDeviceConfigIfEnabled() else { return }

    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(root) }

    let client = ADBClient(adbPath: config.adbPath)
    let device = TestSupport.device(
        serial: config.serial,
        state: .online,
        friendlyName: "Real device",
        androidVersion: nil,
        apiLevel: nil
    )
    let manager = LogSessionManager(logsURL: root.appendingPathComponent("Logs", isDirectory: true)) { _, _ in }
    let session = try manager.startLogStream(device: device, adbPath: config.adbPath, target: .defaultApp)
    defer { manager.stop(session) }

    let echoResult = await client.run(
        serial: config.serial,
        arguments: ["shell", "echo", "DroidScoutIntegration"],
        timeout: 10
    )
    guard echoResult.succeeded else {
        throw RealDeviceTestError.commandFailed(echoResult.stderr.nilIfBlank ?? echoResult.stdout.nilIfBlank ?? "Could not execute a shell command on the selected device.")
    }

    #expect(echoResult.stdout.nilIfBlank == "DroidScoutIntegration")
    #expect(FileManager.default.fileExists(atPath: session.fileURL.pathString))
    #expect(manager.sessions.contains(session))
}

@MainActor
@Test func realDeviceV2Phase1ActionsAreValidAgainstADB() async throws {
    guard let config = try realDeviceConfigIfEnabled() else { return }

    let client = ADBClient(adbPath: config.adbPath)
    
    // Test Screenshot
    let tempScreenshot = FileManager.default.temporaryDirectory.appendingPathComponent("temp_real_screenshot.png")
    defer { try? FileManager.default.removeItem(at: tempScreenshot) }
    let screenshotResult = await client.takeScreenshot(serial: config.serial, localURL: tempScreenshot)
    #expect(screenshotResult.succeeded)
    #expect(FileManager.default.fileExists(atPath: tempScreenshot.pathString))
    
    // Test Port Forwarding/Reverse
    let forwardResult = await client.forwardPort(serial: config.serial, local: "tcp:18080", remote: "tcp:18080")
    #expect(forwardResult.succeeded)
    let removeForwardResult = await client.removeForwardPort(serial: config.serial, local: "tcp:18080")
    #expect(removeForwardResult.succeeded)
}

private func realDeviceConfigIfEnabled() throws -> RealDeviceConfig? {
    let environment = ProcessInfo.processInfo.environment
    guard environment["DROID_SCOUT_REAL_DEVICE_TESTS"] == "1" else {
        return nil
    }
    guard let adbPath = environment["DROID_SCOUT_TEST_ADB_PATH"]?.nilIfBlank else {
        throw RealDeviceTestError.missingADBPath
    }
    guard let serial = environment["DROID_SCOUT_TEST_DEVICE_SERIAL"]?.nilIfBlank else {
        throw RealDeviceTestError.missingSerial
    }
    return RealDeviceConfig(adbPath: adbPath, serial: serial)
}

@MainActor
private func waitForRealDevice(timeout: TimeInterval, condition: @escaping @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return condition()
}
