import Foundation
import Testing
@testable import DroidScout

@Test func deviceConnectionStateAndADBAvailabilityExposeUserFacingState() {
    #expect(AppConstants.appName == "Droid Scout")
    #expect(AppConstants.bundleIdentifier == "com.droidscout.app")
    #expect(AppConstants.applicationSupportURL.lastPathComponent == "Droid Scout")
    #expect(AppConstants.logsURL.lastPathComponent == "Droid Scout")
    #expect(AppConstants.githubReleasesURL.absoluteString.contains("/releases"))

    #expect(DeviceConnectionState(adbState: "device") == .online)
    #expect(DeviceConnectionState(adbState: "unauthorized") == .unauthorized)
    #expect(DeviceConnectionState(adbState: "offline") == .offline)
    #expect(DeviceConnectionState(adbState: "recovery") == .unknown)
    #expect(DeviceConnectionState.stopped.displayName == "stopped")

    let healthy = ADBAvailability.healthy(path: "/opt/adb", version: "Android Debug Bridge version 35")
    #expect(healthy.isHealthy)
    #expect(healthy.path == "/opt/adb")
    #expect(healthy.bannerTitle == nil)
    #expect(healthy.bannerMessage == nil)

    let missing = ADBAvailability.missing(message: "Install platform tools")
    #expect(!missing.isHealthy)
    #expect(missing.path == nil)
    #expect(missing.bannerTitle == "ADB was not found")
    #expect(missing.bannerMessage == "Install platform tools")

    let failedWithPath = ADBAvailability.failed(path: "/bad/adb", message: "boom")
    #expect(failedWithPath.path == "/bad/adb")
    #expect(failedWithPath.bannerTitle == "ADB is not working")
    #expect(failedWithPath.bannerMessage == "boom")

    let failedWithoutPath = ADBAvailability.failed(path: nil, message: "boom")
    #expect(failedWithoutPath.path == nil)
    #expect(ADBAvailability.checking.bannerTitle == "Checking ADB...")
}

@Test func androidDeviceDerivedPropertiesCoverPhysicalAndEmulatorDevices() {
    let longPhysical = TestSupport.device(
        serial: "R58T1234567890",
        friendlyName: "Samsung Galaxy",
        androidVersion: "14",
        apiLevel: "34",
        avdName: nil
    )
    #expect(longPhysical.id == "R58T1234567890")
    #expect(longPhysical.shortSerial == "R58T12...7890")
    #expect(!longPhysical.isEmulator)
    #expect(!longPhysical.canStartEmulator)
    #expect(longPhysical.hiddenIdentity == "R58T1234567890")
    #expect(longPhysical.versionSummary == "Android 14 / API 34")

    let runningAVD = TestSupport.device(
        serial: "emulator-5554",
        friendlyName: "Pixel 8 API 35",
        androidVersion: "15",
        apiLevel: nil,
        transportHint: "Emulator",
        avdName: "Pixel_8_API_35"
    )
    #expect(runningAVD.shortSerial == "emulat...5554")
    #expect(runningAVD.isEmulator)
    #expect(runningAVD.hiddenIdentity == "avd:Pixel_8_API_35")
    #expect(runningAVD.versionSummary == "Android 15")

    let stoppedAVD = TestSupport.device(
        serial: "avd:Tablet_API_34",
        state: .stopped,
        friendlyName: "Tablet API 34",
        androidVersion: nil,
        apiLevel: "34",
        transportHint: "Emulator",
        avdName: "Tablet_API_34"
    )
    #expect(stoppedAVD.shortSerial == "Tablet_API_34")
    #expect(stoppedAVD.canStartEmulator)
    #expect(stoppedAVD.versionSummary == "API 34")

    let unknownVersion = TestSupport.device(serial: "short", androidVersion: nil, apiLevel: nil)
    #expect(unknownVersion.shortSerial == "short")
    #expect(unknownVersion.versionSummary == "Version unknown")
}

@Test func artifactInstallAndSettingsValueSummariesAreStable() throws {
    let apk = TestSupport.artifact(
        paths: ["/tmp/build/app-debug.apk"],
        packageName: nil,
        versionName: "2.1",
        versionCode: "42",
        variant: "debug",
        kind: .apk,
        source: .indexedProject
    )
    #expect(apk.primaryPath == "/tmp/build/app-debug.apk")
    #expect(apk.isReinstallable)
    #expect(apk.displayName == "app-debug.apk")
    #expect(apk.versionSummary == "2.1 (42) debug")
    #expect(apk.reinstallMenuTitle == "app-debug.apk - debug, Project scan")

    let packageOnly = TestSupport.artifact(paths: [], packageName: "com.example", versionName: nil, versionCode: nil, variant: nil)
    #expect(packageOnly.displayName == "com.example")
    #expect(packageOnly.versionSummary == "APK")
    #expect(packageOnly.reinstallMenuTitle == "com.example - Droid Scout")

    let kindOnly = TestSupport.artifact(paths: [], packageName: nil, versionName: nil, versionCode: nil, variant: nil, kind: .splitAPK)
    #expect(kindOnly.primaryPath == nil)
    #expect(kindOnly.displayName == "Split APKs")

    let aab = TestSupport.artifact(paths: ["/tmp/app.aab"], kind: .aab, source: .external)
    #expect(!aab.isReinstallable)
    #expect(aab.kind.displayName == "AAB")
    #expect(ArtifactKind.splitAPK.displayName == "Split APKs")
    #expect(ArtifactSource.external.displayName == "External deploy")

    #expect(DeployConfidence.low < .medium)
    #expect(DeployConfidence.medium < .high)
    #expect(DeployConfidence.low.displayName == "Low")
    #expect(DeployConfidence.medium.displayName == "Medium")
    #expect(DeployConfidence.high.displayName == "High")

    #expect(InstallStatus.queued.displayName == "Queued")
    #expect(!InstallStatus.installing.isTerminal)
    #expect(InstallStatus.success.isTerminal)
    #expect(InstallStatus.failed.displayName == "Failed")
    #expect(InstallStatus.skipped.displayName == "Skipped")

    #expect(NotificationMode.full.id == "full")
    #expect(NotificationMode.full.displayName == "Full")
    #expect(NotificationMode.reduced.displayName == "Reduced")
    #expect(NotificationMode.off.displayName == "Off")
    #expect(LogTarget.terminal.id == "terminal")
    #expect(LogTarget.terminal.displayName == "Terminal")
    #expect(LogTarget.vscode.displayName == "VS Code")
    #expect(LogTarget.zed.displayName == "Zed")
    #expect(LogTarget.defaultApp.displayName == "Default App")

    let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"notificationMode":"off","confidenceThreshold":"high"}"#.utf8))
    #expect(decoded.customADBPath == nil)
    #expect(decoded.watchedProjectPaths == [])
    #expect(decoded.notificationMode == .off)
    #expect(decoded.logTarget == .terminal)
    #expect(decoded.logRetentionDays == AppSettings.defaults.logRetentionDays)
    #expect(decoded.packagePollingInterval == AppSettings.defaults.packagePollingInterval)
    #expect(decoded.confidenceThreshold == .high)
    #expect(decoded.backgroundUpdateChecks)
    #expect(decoded.hiddenDeviceIdentities == [])
}
