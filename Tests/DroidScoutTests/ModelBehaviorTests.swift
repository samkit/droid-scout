import AppKit
import Foundation
import Testing
@testable import DroidScout

@MainActor
@Test func modelInitializesFromStoreAndComputesVisibleSelectionAndBanners() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(root) }
    let store = LocalStore(
        supportURL: root.appendingPathComponent("Support", isDirectory: true),
        logsURL: root.appendingPathComponent("Logs", isDirectory: true)
    )
    var savedSettings = AppSettings.defaults
    savedSettings.logRetentionDays = 14
    savedSettings.notificationMode = .off
    savedSettings.hiddenDeviceIdentities = ["USB-HIDDEN", "avd:Hidden_API"]
    store.saveSettings(savedSettings)
    store.saveActivities([
        ActivityEvent(id: UUID(), timestamp: Date(), kind: .adb, title: "loaded", detail: "activity", deviceSerials: [], success: true)
    ])
    store.saveArtifacts([
        TestSupport.artifact(paths: ["/tmp/old.apk"], packageName: "com.loaded", lastSeen: Date(timeIntervalSince1970: 10))
    ])
    store.saveDeviceNames(["USB-CACHED": "Cached Pixel"])

    let model = DroidScoutModel(store: store)
    #expect(model.settings.logRetentionDays == AppSettings.defaults.logRetentionDays)
    #expect(model.settings.notificationMode == .off)
    #expect(model.activities.first?.title == "loaded")
    #expect(model.artifacts.first?.packageName == "com.loaded")

    let online = TestSupport.device(serial: "USB-ONLINE", state: .online, friendlyName: "Online Pixel")
    let unauthorized = TestSupport.device(serial: "USB-AUTH", state: .unauthorized, friendlyName: "Auth Pixel")
    let hidden = TestSupport.device(serial: "USB-HIDDEN", state: .online, friendlyName: "Hidden Pixel")
    let stoppedHidden = TestSupport.device(serial: "avd:Hidden_API", state: .stopped, friendlyName: "Hidden API", avdName: "Hidden_API")
    model.applyDeviceSnapshot([unauthorized, stoppedHidden, hidden, online])

    #expect(model.devices.map(\.serial) == ["USB-HIDDEN", "USB-ONLINE", "USB-AUTH", "avd:Hidden_API"])
    #expect(model.visibleDevices.map(\.serial) == ["USB-ONLINE", "USB-AUTH"])
    #expect(model.hiddenDeviceCount == 2)
    #expect(model.onlineDevices.map(\.serial) == ["USB-ONLINE"])
    #expect(model.selectedOnlineDevices.map(\.serial) == ["USB-ONLINE"])
    #expect(model.selectedSerials == ["USB-ONLINE"])

    model.adbStatus = .missing(message: "Install ADB")
    #expect(model.statusBanner?.title == "ADB was not found")
    #expect(model.statusBanner?.style == .error)
    model.adbStatus = .healthy(path: "/tmp/adb", version: "ok")
    #expect(model.statusBanner?.title == "Device authorization needed")
    #expect(model.statusBanner?.style == .warning)

    model.applyDeviceSnapshot([TestSupport.device(serial: "USB-OFF", state: .offline, friendlyName: "Offline Pixel")])
    #expect(model.statusBanner?.title == "Offline device detected")

    model.hideDevice(online)
    #expect(model.settings.hiddenDeviceIdentities.contains("USB-ONLINE"))
    #expect(!model.selectedSerials.contains("USB-ONLINE"))
    model.showHiddenDevices()
    #expect(model.settings.hiddenDeviceIdentities.isEmpty)
    #expect(model.activities.first?.title == "Hidden devices shown")
}

@MainActor
@Test func modelSyncsLaunchAtLoginSettingThroughSystemActions() throws {
    enum LaunchAtLoginError: Error {
        case denied
    }

    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(root) }
    let store = LocalStore(
        supportURL: root.appendingPathComponent("Support", isDirectory: true),
        logsURL: root.appendingPathComponent("Logs", isDirectory: true)
    )
    var systemLaunchAtLogin = false
    var shouldFail = false
    let model = DroidScoutModel(
        store: store,
        launchAtLoginStatusProvider: { systemLaunchAtLogin },
        launchAtLoginSetter: { enabled in
            if shouldFail {
                throw LaunchAtLoginError.denied
            }
            systemLaunchAtLogin = enabled
        }
    )

    #expect(!model.settings.launchAtLogin)
    model.setLaunchAtLoginEnabled(true)
    #expect(model.settings.launchAtLogin)
    #expect(store.loadSettings().launchAtLogin)
    #expect(model.activities.first?.title == "Launch at login enabled")

    shouldFail = true
    model.setLaunchAtLoginEnabled(false)
    #expect(model.settings.launchAtLogin)
    #expect(store.loadSettings().launchAtLogin)
    #expect(model.activities.first?.title == "Launch at login update failed")

    systemLaunchAtLogin = false
    model.refreshLaunchAtLoginStatus()
    #expect(!model.settings.launchAtLogin)
}

@MainActor
@Test func modelMergesArtifactsClearsResultsAndScansProjects() async throws {
    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(root) }
    let store = LocalStore(
        supportURL: root.appendingPathComponent("Support", isDirectory: true),
        logsURL: root.appendingPathComponent("Logs", isDirectory: true)
    )
    let model = DroidScoutModel(store: store)
    model.settings.notificationMode = .off

    let older = TestSupport.artifact(
        paths: ["/tmp/app.apk"],
        packageName: nil,
        lastSeen: Date(timeIntervalSince1970: 10),
        devices: ["USB1"],
        perDeviceResults: ["USB1": "Failed"]
    )
    let newer = TestSupport.artifact(
        paths: ["/tmp/app.apk"],
        packageName: "com.example",
        lastSeen: Date(timeIntervalSince1970: 20),
        devices: ["USB2"],
        perDeviceResults: ["USB2": "Success"]
    )
    let separate = TestSupport.artifact(paths: ["/tmp/other.apk"], lastSeen: Date(timeIntervalSince1970: 30))
    let merged = model.mergeArtifacts([older, newer, separate])
    #expect(merged.map(\.paths) == [["/tmp/other.apk"], ["/tmp/app.apk"]])
    #expect(merged[1].packageName == "com.example")
    #expect(merged[1].devices == ["USB1", "USB2"])
    #expect(merged[1].perDeviceResults == ["USB1": "Failed", "USB2": "Success"])

    model.installResults = [
        InstallResult(id: UUID(), deviceSerial: "a", artifactID: UUID(), artifactName: "app", artifactPath: nil, status: .queued, stdout: "", stderr: "", startedAt: Date(), completedAt: nil),
        InstallResult(id: UUID(), deviceSerial: "b", artifactID: UUID(), artifactName: "app", artifactPath: nil, status: .installing, stdout: "", stderr: "", startedAt: Date(), completedAt: nil),
        InstallResult(id: UUID(), deviceSerial: "c", artifactID: UUID(), artifactName: "app", artifactPath: nil, status: .success, stdout: "", stderr: "", startedAt: Date(), completedAt: Date()),
        InstallResult(id: UUID(), deviceSerial: "d", artifactID: UUID(), artifactName: "app", artifactPath: nil, status: .failed, stdout: "", stderr: "", startedAt: Date(), completedAt: Date()),
        InstallResult(id: UUID(), deviceSerial: "e", artifactID: UUID(), artifactName: "app", artifactPath: nil, status: .skipped, stdout: "", stderr: "", startedAt: Date(), completedAt: Date())
    ]
    model.clearCompletedInstallResults()
    #expect(model.installResults.map(\.status) == [.queued, .installing])

    let project = root.appendingPathComponent("AndroidProject", isDirectory: true)
    let apk = project.appendingPathComponent("app/build/outputs/apk/freeDebug/app-free-debug.apk")
    try TestSupport.touch(apk, modifiedAt: Date(timeIntervalSince1970: 100))
    try TestSupport.write(
        """
        {"applicationId":"com.scanned","elements":[{"versionCode":5,"versionName":"1.5","outputFile":"app-free-debug.apk"}]}
        """,
        to: apk.deletingLastPathComponent().appendingPathComponent("output-metadata.json")
    )

    model.settings.watchedProjectPaths = [project.pathString]
    await model.scanProjects()
    #expect(model.artifacts.contains { $0.packageName == "com.scanned" && $0.variant == "freeDebug" })
    #expect(model.activities.first?.title == "Project artifacts indexed")
    #expect(store.loadArtifacts().contains { $0.packageName == "com.scanned" })

    model.removeProjectFolder(project.pathString)
    #expect(model.settings.watchedProjectPaths.isEmpty)
}

@MainActor
@Test func modelDetectsADBInstallsRecentArtifactAndRestartsServerThroughFakeADB() async throws {
    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(root) }
    let support = root.appendingPathComponent("Support", isDirectory: true)
    let logs = root.appendingPathComponent("Logs", isDirectory: true)
    let store = LocalStore(supportURL: support, logsURL: logs)
    let model = DroidScoutModel(store: store)
    model.settings.notificationMode = .off

    let adb = root.appendingPathComponent("adb")
    let calls = root.appendingPathComponent("calls.txt")
    try TestSupport.executableScript(adb, body: """
    echo "$@" >> "\(calls.pathString)"
    case "$1" in
      version)
        echo "Android Debug Bridge version 35.0.2"
        exit 0
        ;;
      track-devices)
        sleep 20
        exit 0
        ;;
      devices)
        echo "List of devices attached"
        echo "USB1 device model:Pixel_8 usb:1"
        exit 0
        ;;
      kill-server|start-server)
        echo "$1 ok"
        exit 0
        ;;
      pair)
        echo "Successfully paired to $2 with code $3"
        exit 0
        ;;
      -s)
        if [ "$3" = "install" ]; then
          echo "Success"
          exit 0
        fi
        if [ "$3" = "logcat" ] && [ "$4" = "-c" ]; then
          echo "cleared"
          exit 0
        fi
        if [ "$3" = "shell" ] && [ "$4" = "dumpsys" ]; then
          echo "No packages"
          exit 0
        fi
        ;;
    esac
    exit 0
    """)
    model.settings.customADBPath = adb.pathString
    await model.detectADB()
    #expect(model.adbStatus.isHealthy)
    model.retryADBDetection()
    let retryCompleted = await waitUntil(timeout: 3) {
        model.adbStatus.isHealthy
    }
    #expect(retryCompleted)
    await model.detectADB()

    let device = TestSupport.device(serial: "USB1", state: .online, friendlyName: "Pixel 8")
    model.applyDeviceSnapshot([device])
    model.refreshDevices()
    let refreshCompleted = await waitUntil(timeout: 3) {
        !model.isRefreshingDevices
    }
    #expect(refreshCompleted)

    let apk = root.appendingPathComponent("app.apk")
    try TestSupport.touch(apk)
    let artifact = TestSupport.artifact(paths: [apk.pathString], packageName: "com.example.app", devices: ["USB1"])
    model.reinstallRecent(artifact)

    let installCompleted = await waitUntil(timeout: 3) {
        model.activities.contains { $0.title.hasPrefix("Install completed") }
    }
    #expect(installCompleted)
    #expect(model.installResults.contains { $0.deviceSerial == "USB1" && $0.status == .success })
    #expect(model.artifacts.contains { $0.paths == [apk.pathString] && $0.perDeviceResults["USB1"] == "Success" })

    model.clearLogcatForSelected()
    let clearCompleted = await waitUntil(timeout: 3) {
        model.activities.contains { $0.title == "Logcat buffer cleared" }
    }
    #expect(clearCompleted)

    model.restartADBServer()
    let restartCompleted = await waitUntil(timeout: 3) {
        model.activities.contains { $0.title == "ADB server restarted" } &&
            !model.isRestartingADBServer &&
            model.adbStatus.isHealthy
    }
    #expect(restartCompleted)

    model.pairAndroidDevice(address: "192.168.1.10:37123", pairingCode: "123456")
    let pairingCompleted = await waitUntil(timeout: 3) {
        model.activities.contains { $0.title == "Android device paired" }
    }
    #expect(pairingCompleted)
    #expect(model.activities.first { $0.title == "Android device paired" }?.detail == "Successfully paired to 192.168.1.10:37123 with code [code]")

    let failingADB = root.appendingPathComponent("adb-failing")
    try TestSupport.executableScript(failingADB, body: "echo no >&2; exit 4")
    model.settings.customADBPath = failingADB.pathString
    model.retryADBDetection()
    let failedRetryCompleted = await waitUntil(timeout: 3) {
        !model.adbStatus.isHealthy
    }
    #expect(failedRetryCompleted)
    await model.detectADB()
    #expect(!model.adbStatus.isHealthy)
}

@MainActor
@Test func modelRecordsUnavailableActionsWithoutStartingSystemUI() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(root) }
    let store = LocalStore(
        supportURL: root.appendingPathComponent("Support", isDirectory: true),
        logsURL: root.appendingPathComponent("Logs", isDirectory: true)
    )
    let model = DroidScoutModel(store: store)
    model.settings.notificationMode = .off

    model.restartADBServer()
    #expect(model.activities.first?.title == "ADB restart unavailable")

    let aab = TestSupport.artifact(paths: ["/tmp/app.aab"], kind: .aab)
    model.reinstallRecent(aab)
    #expect(model.activities.first?.title == "Artifact not installable")

    let stopped = TestSupport.device(serial: "avd:Pixel", state: .stopped, friendlyName: "Pixel", avdName: "Pixel")
    model.startEmulator(device: stopped)
    #expect(model.activities.first?.title == "Emulator start failed")

    model.showHiddenDevices()
    #expect(model.activities.first?.title == "Emulator start failed")

    model.copySerial(TestSupport.device(serial: "COPY-ME", friendlyName: "Copy Phone"))
    #expect(model.activities.first?.title == "Serial copied")

    model.stopLogSession(LogSessionManager.Session(
        id: UUID(),
        deviceSerial: "USB1",
        fileURL: root.appendingPathComponent("missing.log"),
        startedAt: Date()
    ))
    #expect(model.activeLogSessions.isEmpty)

    model.restartToApplyUpdate()
    #expect(model.activities.first?.title == "Restart unavailable")
}

@MainActor
@Test func defaultSystemActionsAndModelBoundariesAreInertButCallable() async throws {
    guard ProcessInfo.processInfo.environment["DROID_SCOUT_MODEL_BOUNDARY_TESTS"] == "1" else {
        return
    }

    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(root) }

    let actions = DroidScoutSystemActions()
    #expect(actions.chooseADBURLProvider() == nil)
    #expect(actions.projectFolderURLsProvider().isEmpty)
    #expect(actions.installAPKURLsProvider().isEmpty)
    actions.textCopier("copy")
    actions.shellOpener("echo shell")
    actions.diagnosticsRevealer(root)
    #expect(actions.appBundleURLProvider() == nil)
    actions.restartLauncher(root)
    actions.appTerminator()
    actions.logOpener(root.appendingPathComponent("log.txt"), .terminal)
    actions.logsRevealer(root)
    actions.notificationAuthorizationRequester()
    actions.notificationDeliverer("Title", "Body")
    actions.updateOpener(AppConstants.githubReleasesURL)

    let notificationManager = AppNotificationManager()
    notificationManager.requestAuthorization()
    notificationManager.notify(kind: .install, title: "Install", body: "Done", mode: .full, key: "install")

    let logs = root.appendingPathComponent("Logs", isDirectory: true)
    let logManager = LogSessionManager(logsURL: logs)
    let session = try logManager.startLogStream(
        device: TestSupport.device(serial: "USB-DEFAULT", friendlyName: "Default Phone"),
        adbPath: "/bin/echo",
        target: .defaultApp
    )
    logManager.stop(session)
    _ = try logManager.startLogStream(
        device: TestSupport.device(serial: "USB-STOPALL", friendlyName: "Stop All Phone"),
        adbPath: "/bin/echo",
        target: .terminal
    )
    logManager.stopAll()
    logManager.revealLogsFolder()

    let updateService = UpdateService()
    updateService.checkForUpdates()

    let store = LocalStore(
        supportURL: root.appendingPathComponent("Support", isDirectory: true),
        logsURL: logs
    )
    let model = DroidScoutModel(
        store: store,
        notificationManager: AppNotificationManager(),
        logSessionManager: LogSessionManager(logsURL: logs),
        updateService: UpdateService()
    )
    model.chooseADB()
    model.addProjectFolder()
    model.installAPKFromPanel()
    model.installAPKFromMainAction()
    model.copyHomebrewInstallHint()
    model.adbStatus = .healthy(path: "/bin/echo", version: "echo")
    model.openShell(device: TestSupport.device(serial: "USB-DEFAULT"))
    model.revealLogs()
    model.checkForUpdates()
    model.exportDiagnostics()
    model.restartToApplyUpdate()
    model.quit()

    let device = TestSupport.device(serial: "USB-POLL", friendlyName: "Poll Phone")
    model.devices = [device]
    model.settings.notificationMode = .off
    model.settings.confidenceThreshold = .low
    model.artifacts = [
        TestSupport.artifact(
            paths: [root.appendingPathComponent("polled.apk").pathString],
            packageName: "com.example.polled",
            versionName: "1.0",
            versionCode: "1",
            source: .indexedProject
        )
    ]
    model.applyPackageSnapshots([
        PackageSnapshot(
            deviceSerial: device.serial,
            packageName: "com.example.polled",
            versionName: "1.0",
            versionCode: "1",
            firstInstallTime: nil,
            lastUpdateTime: "2026-05-28 12:00:00",
            observedAt: Date()
        )
    ])
    model.applyPackageSnapshots([
        PackageSnapshot(
            deviceSerial: device.serial,
            packageName: "com.example.polled",
            versionName: "1.0",
            versionCode: "2",
            firstInstallTime: nil,
            lastUpdateTime: "2026-05-28 12:05:00",
            observedAt: Date()
        )
    ])
    #expect(model.activities.first?.title == "External deploy detected")

    let restartModel = DroidScoutModel(
        store: LocalStore(
            supportURL: root.appendingPathComponent("RestartSupport", isDirectory: true),
            logsURL: logs
        ),
        appBundleURLProvider: { root.appendingPathComponent("Droid Scout.app", isDirectory: true) }
    )
    restartModel.restartToApplyUpdate()
    #expect(restartModel.activities.first?.title == "Restarting Droid Scout")

    let badSupportFile = root.appendingPathComponent("support-file")
    try TestSupport.touch(badSupportFile)
    let diagnosticsFailureModel = DroidScoutModel(
        store: LocalStore(
            supportURL: badSupportFile,
            logsURL: root.appendingPathComponent("DiagnosticsFailureLogs", isDirectory: true)
        )
    )
    diagnosticsFailureModel.exportDiagnostics()
    #expect(diagnosticsFailureModel.activities.first?.title == "Diagnostics export failed")

    let watcherADB = root.appendingPathComponent("watcher-adb")
    try TestSupport.executableScript(watcherADB, body: """
    if [ "$1" = "version" ]; then
      rm "$0"
      echo "Android Debug Bridge version 35.0.2"
      exit 0
    fi
    exit 0
    """)
    let watcherFailureModel = DroidScoutModel(
        store: LocalStore(
            supportURL: root.appendingPathComponent("WatcherSupport", isDirectory: true),
            logsURL: root.appendingPathComponent("WatcherLogs", isDirectory: true)
        )
    )
    watcherFailureModel.settings.customADBPath = watcherADB.pathString
    await watcherFailureModel.detectADB()
    #expect(watcherFailureModel.activities.contains { $0.title == "ADB watcher stopped" })

    let sdk = root.appendingPathComponent("BadEmulatorSDK", isDirectory: true)
    let adb = sdk.appendingPathComponent("platform-tools/adb")
    let emulator = sdk.appendingPathComponent("emulator/emulator")
    try TestSupport.executableScript(adb, body: """
    if [ "$1" = "version" ]; then
      echo "Android Debug Bridge version 35.0.2"
      exit 0
    fi
    if [ "$1" = "track-devices" ]; then
      sleep 20
      exit 0
    fi
    if [ "$1" = "devices" ]; then
      echo "List of devices attached"
      exit 0
    fi
    exit 0
    """)
    try TestSupport.write("not a runnable emulator binary", to: emulator)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: emulator.pathString)
    let emulatorFailureModel = DroidScoutModel(
        store: LocalStore(
            supportURL: root.appendingPathComponent("EmulatorFailureSupport", isDirectory: true),
            logsURL: root.appendingPathComponent("EmulatorFailureLogs", isDirectory: true)
        )
    )
    emulatorFailureModel.settings.customADBPath = adb.pathString
    await emulatorFailureModel.detectADB()
    emulatorFailureModel.startEmulator(device: TestSupport.device(
        serial: "avd:Broken",
        state: .stopped,
        friendlyName: "Broken",
        avdName: "Broken"
    ))
    #expect(emulatorFailureModel.activities.first?.title == "Emulator start failed")

    try await stopADBBackedServices(model, root: root)
    try await stopADBBackedServices(watcherFailureModel, root: root)
    try await stopADBBackedServices(emulatorFailureModel, root: root)
}

@MainActor
@Test func modelPanelHelpersLogsPackageChangesAndInjectedAppActionsUseRealBoundaries() async throws {
    guard ProcessInfo.processInfo.environment["DROID_SCOUT_MODEL_BOUNDARY_TESTS"] == "1" else {
        return
    }

    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(root) }

    let store = LocalStore(
        supportURL: root.appendingPathComponent("Support", isDirectory: true),
        logsURL: root.appendingPathComponent("Logs", isDirectory: true)
    )
    var revealedLogs: [URL] = []
    var openedUpdates: [URL] = []
    var deliveredNotifications: [(String, String)] = []
    var openedShells: [String] = []
    var revealedDiagnostics: [URL] = []
    var launchedRestarts: [URL] = []
    var terminationCount = 0
    var authorizationRequests = 0
    let adb = root.appendingPathComponent("adb")
    let projectFromPanel = root.appendingPathComponent("ProjectFromPanel", isDirectory: true)
    let apkFromPanel = root.appendingPathComponent("panel.apk")
    let logManager = LogSessionManager(
        logsURL: root.appendingPathComponent("Logs", isDirectory: true),
        openLogHandler: { _, _ in },
        revealLogsHandler: { revealedLogs.append($0) }
    )
    let notificationManager = AppNotificationManager(
        requestAuthorizationHandler: { authorizationRequests += 1 },
        deliverNotification: { title, body in deliveredNotifications.append((title, body)) }
    )
    let updateService = UpdateService { openedUpdates.append($0) }
    let model = DroidScoutModel(
        store: store,
        notificationManager: notificationManager,
        logSessionManager: logManager,
        updateService: updateService,
        chooseADBURLProvider: { adb },
        projectFolderURLsProvider: { [projectFromPanel] },
        installAPKURLsProvider: { [apkFromPanel] },
        shellOpener: { openedShells.append($0) },
        diagnosticsRevealer: { revealedDiagnostics.append($0) },
        appBundleURLProvider: { root.appendingPathComponent("Droid Scout.app", isDirectory: true) },
        restartLauncher: { launchedRestarts.append($0) },
        appTerminator: { terminationCount += 1 }
    )

    let packageState = root.appendingPathComponent("package-state.txt")
    try TestSupport.write("2026-05-28 12:00:00", to: packageState)
    try TestSupport.executableScript(adb, body: """
    if [ "$1" = "version" ]; then
      echo "Android Debug Bridge version 35.0.2"
      exit 0
    fi
    if [ "$1" = "track-devices" ]; then
      sleep 20
      exit 0
    fi
    if [ "$1" = "devices" ]; then
      echo "List of devices attached"
      exit 0
    fi
    if [ "$1" = "-s" ] && [ "$3" = "install" ]; then
      echo "install failed" >&2
      exit 9
    fi
    if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "dumpsys" ]; then
      echo "Package [$6]"
      echo "versionCode=1 minSdk=23 targetSdk=35"
      echo "versionName=1.0"
      echo "firstInstallTime=2026-05-28 11:00:00"
      printf "lastUpdateTime="
      cat "\(packageState.pathString)"
      exit 0
    fi
    exit 0
    """)
    let startADB = root.appendingPathComponent("start-adb")
    try TestSupport.executableScript(startADB, body: "echo start failed >&2; exit 4")
    model.settings.customADBPath = startADB.pathString
    model.start()
    let startedWithMissingADB = await waitUntil(timeout: 3) {
        authorizationRequests == 1 && model.activities.contains { $0.title == "ADB setup needed" }
    }
    #expect(startedWithMissingADB)

    model.chooseADB()
    await model.detectADB()
    #expect(model.adbStatus.isHealthy)

    let projectA = root.appendingPathComponent("ProjectA", isDirectory: true)
    let projectB = root.appendingPathComponent("ProjectB", isDirectory: true)
    model.settings.watchedProjectPaths = [projectB.pathString]
    model.addProjectFolders([projectA, projectB])
    #expect(model.settings.watchedProjectPaths == [projectA.pathString, projectB.pathString].sorted())
    model.addProjectFolder()
    #expect(model.settings.watchedProjectPaths.contains(projectFromPanel.pathString))
    model.scanProjectsFromUI()
    let scanFromUIRecorded = await waitUntil(timeout: 3) {
        model.activities.contains { $0.title == "Project artifacts indexed" }
    }
    #expect(scanFromUIRecorded)

    model.installAPK(urls: [root.appendingPathComponent("bundle.aab")])
    #expect(model.activities.first?.title == "AAB not installable")

    let chosenAPK = root.appendingPathComponent("chosen.apk")
    try TestSupport.touch(chosenAPK)
    try TestSupport.touch(apkFromPanel)
    model.devices = [TestSupport.device(serial: "USB1", state: .online, friendlyName: "Install Phone")]
    model.selectedSerials = ["USB1"]
    model.installAPKFromPanel()
    let panelInstallFinished = await waitUntil(timeout: 3) {
        model.activities.contains { $0.title == "Install completed with failures" }
    }
    #expect(panelInstallFinished)
    model.installAPK(urls: [chosenAPK], preselectedSerial: "USB1")
    let selectedInstallFinished = await waitUntil(timeout: 3) {
        model.activities.contains { $0.title == "Install completed with failures" }
    }
    #expect(selectedInstallFinished)

    let existingArtifact = TestSupport.artifact(paths: [root.appendingPathComponent("existing.apk").pathString])
    model.artifacts = [existingArtifact]
    let existingInstall = model.artifactForInstall(paths: existingArtifact.paths)
    #expect(existingInstall.paths == existingArtifact.paths)
    #expect(existingInstall.source == .droidScout)

    let split = model.artifactForInstall(paths: [
        root.appendingPathComponent("base.apk").pathString,
        root.appendingPathComponent("config.apk").pathString
    ])
    #expect(split.kind == .splitAPK)
    #expect(split.evidence == "Chosen manually; APK metadata was not available.")
    await model.install(artifact: TestSupport.artifact(paths: [chosenAPK.pathString], kind: .aab), devices: model.devices)
    #expect(model.activities.first?.title == "Artifact not installable")

    let online = TestSupport.device(serial: "USB LOG", state: .online, friendlyName: "Log Phone")
    model.devices = [online]
    model.selectedSerials = [online.serial]
    model.adbStatus = .healthy(path: "/bin/echo", version: "echo")
    model.startLogsForSelected()
    #expect(model.activities.first?.title == "Log stream started")
    #expect(model.activeLogSessions.count == 1)
    if let session = model.activeLogSessions.first {
        model.stopLogSession(session)
    }

    model.adbStatus = .healthy(path: "/definitely/missing/adb", version: "missing")
    model.startLogsForSelected()
    #expect(model.activities.first?.title == "Log stream failed")

    #expect(model.shellCommand(device: online)?.contains("-s 'USB LOG' shell") == true)
    model.openShell(device: online)
    #expect(openedShells.first?.contains("-s 'USB LOG' shell") == true)
    model.adbStatus = .missing(message: "missing")
    #expect(model.shellCommand(device: online) == nil)

    model.revealLogs()
    #expect(revealedLogs.count == 1)
    model.checkForUpdates()
    #expect(openedUpdates == [AppConstants.githubReleasesURL])
    #expect(model.activities.first?.title == "Checking for updates")
    model.exportDiagnostics()
    #expect(revealedDiagnostics.count == 1)
    #expect(model.activities.first?.title == "Diagnostics exported")
    model.restartToApplyUpdate()
    #expect(launchedRestarts == [root.appendingPathComponent("Droid Scout.app", isDirectory: true)])
    #expect(terminationCount == 1)

    model.settings.notificationMode = .full
    model.settings.confidenceThreshold = .low
    model.devices = [TestSupport.device(serial: "USB1", friendlyName: "Pixel 8")]
    model.artifacts = [
        TestSupport.artifact(
            paths: [root.appendingPathComponent("external.apk").pathString],
            packageName: "com.example.external",
            versionName: "1.0",
            versionCode: "1",
            source: .indexedProject
        )
    ]
    model.handlePackageChange(PackageSnapshot(
        deviceSerial: "USB1",
        packageName: "com.example.external",
        versionName: "1.0",
        versionCode: "1",
        firstInstallTime: nil,
        lastUpdateTime: "2026-05-28 12:00:00",
        observedAt: Date()
    ))
    #expect(model.activities.first?.title == "External deploy detected")
    #expect(model.artifacts.first?.source == .external)
    #expect(deliveredNotifications.contains { $0.0 == "External deploy detected" })

    model.quit()
    #expect(terminationCount == 2)
    try await stopADBBackedServices(model, root: root)
}

@MainActor
@Test func modelInstallAndDeviceBranchesCoverFailuresAndEmulatorStart() async throws {
    guard ProcessInfo.processInfo.environment["DROID_SCOUT_MODEL_BOUNDARY_TESTS"] == "1" else {
        return
    }

    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(root) }
    let model = DroidScoutModel(
        store: LocalStore(
            supportURL: root.appendingPathComponent("Support", isDirectory: true),
            logsURL: root.appendingPathComponent("Logs", isDirectory: true)
        ),
        notificationManager: AppNotificationManager(
            requestAuthorizationHandler: {},
            deliverNotification: { _, _ in }
        )
    )
    model.settings.notificationMode = .off

    let installable = TestSupport.artifact(paths: [root.appendingPathComponent("app.apk").pathString])
    await model.install(artifact: installable, devices: [TestSupport.device(serial: "USB1")])
    #expect(model.activities.first?.title == "Install unavailable")

    let sdk = root.appendingPathComponent("sdk", isDirectory: true)
    let adb = sdk.appendingPathComponent("platform-tools/adb")
    let emulator = sdk.appendingPathComponent("emulator/emulator")
    let emulatorCalls = root.appendingPathComponent("emulator-calls.txt")
    try TestSupport.executableScript(adb, body: """
    if [ "$1" = "version" ]; then
      echo "Android Debug Bridge version 35.0.2"
      exit 0
    fi
    if [ "$1" = "track-devices" ]; then
      sleep 20
      exit 0
    fi
    if [ "$1" = "devices" ]; then
      echo "List of devices attached"
      exit 0
    fi
    if [ "$1" = "kill-server" ]; then
      echo "kill failed" >&2
      exit 2
    fi
    if [ "$1" = "-s" ] && [ "$3" = "install" ]; then
      echo "install failed" >&2
      exit 9
    fi
    exit 0
    """)
    try TestSupport.executableScript(emulator, body: """
    echo "$@" >> "\(emulatorCalls.pathString)"
    exit 0
    """)

    model.settings.customADBPath = adb.pathString
    await model.detectADB()
    #expect(model.adbStatus.isHealthy)

    await model.install(artifact: installable, devices: [TestSupport.device(serial: "USB1")])
    #expect(model.activities.first?.title == "Artifact unavailable")

    let apk = root.appendingPathComponent("app.apk")
    try TestSupport.touch(apk)
    let artifact = TestSupport.artifact(paths: [apk.pathString])
    await model.install(artifact: artifact, devices: [])
    #expect(model.activities.first?.title == "No online devices selected")

    model.settings.notificationMode = .full
    await model.install(artifact: artifact, devices: [TestSupport.device(serial: "fail-device")])
    #expect(model.activities.first?.title == "Install completed with failures")

    model.restartADBServer()
    let restartFailed = await waitUntil(timeout: 3) {
        model.activities.contains { $0.title == "ADB server restart failed" }
            && !model.isRestartingADBServer
            && model.adbStatus.isHealthy
    }
    #expect(restartFailed)

    let stopped = TestSupport.device(serial: "avd:Pixel_API", state: .stopped, friendlyName: "Pixel API", avdName: "Pixel_API")
    model.startEmulator(device: stopped)
    #expect(model.activities.first?.title == "Emulator starting")
    #expect(model.isLaunchingEmulator(device: stopped))
    let emulatorLaunched = await waitUntil(timeout: 2) {
        (try? String(contentsOf: emulatorCalls))?.contains("-avd Pixel_API") == true
    }
    #expect(emulatorLaunched)
    let calls = try String(contentsOf: emulatorCalls)
    #expect(calls.contains("-avd Pixel_API"))

    let runningEmulator = TestSupport.device(serial: "emulator-5554", state: .online, friendlyName: "Pixel API", avdName: "Pixel_API")
    model.applyDeviceSnapshot([runningEmulator])
    #expect(!model.isLaunchingEmulator(device: stopped))
    model.applyDeviceSnapshot([])
    #expect(model.activities.first?.title == "Device disconnected")

    try await stopADBBackedServices(model, root: root)
}

@MainActor
@Test func modelV2Phase1ActionsAreCalledAndLoggedThroughFakeADB() async throws {
    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(root) }
    
    let support = root.appendingPathComponent("Support", isDirectory: true)
    let logs = root.appendingPathComponent("Logs", isDirectory: true)
    let store = LocalStore(supportURL: support, logsURL: logs)
    
    var savedScreenshots: [URL] = []
    var savedRecordings: [URL] = []
    var promptedTitles: [String] = []
    var portForwardPromptCalled = false
    
    let actions = DroidScoutSystemActions(
        saveURLProvider: { name, ext in
            if ext == "png" {
                let url = root.appendingPathComponent(name)
                savedScreenshots.append(url)
                return url
            } else {
                let url = root.appendingPathComponent(name)
                savedRecordings.append(url)
                return url
            }
        },
        packagePromptProvider: { title, msg in
            promptedTitles.append(title)
            return "com.test.pkg"
        },
        portForwardPromptProvider: {
            portForwardPromptCalled = true
            return ("forward", "tcp:8080", "tcp:8080")
        }
    )
    
    let model = DroidScoutModel(store: store, systemActions: actions)
    model.settings.notificationMode = .off
    
    let adb = root.appendingPathComponent("adb")
    let adbCalls = root.appendingPathComponent("adb-calls.txt")
    try TestSupport.executableScript(adb, body: """
    echo "$@" >> "\(adbCalls.pathString)"
    case "$1" in
      version)
        echo "Android Debug Bridge version 35.0.2"
        exit 0
        ;;
      track-devices)
        sleep 20
        exit 0
        ;;
      devices)
        echo "List of devices attached"
        echo "USB1 device model:Pixel_8"
        exit 0
        ;;
    esac
    exit 0
    """)
    
    model.settings.customADBPath = adb.pathString
    await model.detectADB()
    #expect(model.adbStatus.isHealthy)
    
    let device = TestSupport.device(serial: "USB1", state: .online, friendlyName: "Pixel 8")
    model.applyDeviceSnapshot([device])
    
    // Test Screenshot
    model.takeScreenshot(device: device)
    let screenshotLogged = await waitUntil(timeout: 3) {
        model.activities.contains { $0.title == "Screenshot saved" }
    }
    #expect(screenshotLogged)
    #expect(savedScreenshots.count == 1)
    
    // Test Screen Recording
    model.startScreenRecording(device: device)
    #expect(model.activeScreenRecordings[device.serial] != nil)
    #expect(model.activities.contains { $0.title == "Screen recording started" })
    
    model.stopScreenRecording(device: device)
    let recordingLogged = await waitUntil(timeout: 3) {
        model.activities.contains { $0.title == "Screen recording saved" }
    }
    #expect(recordingLogged)
    #expect(model.activeScreenRecordings[device.serial] == nil)
    #expect(savedRecordings.count == 1)

    // Test Screen Recording Discard
    model.startScreenRecording(device: device)
    #expect(model.activeScreenRecordings[device.serial] != nil)
    
    model.discardScreenRecording(device: device)
    let discardLogged = await waitUntil(timeout: 3) {
        model.activities.contains { $0.title == "Discarded screen recording" }
    }
    #expect(discardLogged)
    #expect(model.activeScreenRecordings[device.serial] == nil)
    
    // Test App Control (Clear Data / Uninstall)
    model.promptAndClearAppData(device: device)
    let clearLogged = await waitUntil(timeout: 3) {
        model.activities.contains { $0.title == "App data cleared" }
    }
    #expect(clearLogged)
    #expect(promptedTitles.contains("Clear App Data"))
    
    model.promptAndUninstallApp(device: device)
    let uninstallLogged = await waitUntil(timeout: 3) {
        model.activities.contains { $0.title == "App uninstalled" }
    }
    #expect(uninstallLogged)
    #expect(promptedTitles.contains("Uninstall App"))
    
    // Test Reboot
    model.rebootDevice(device: device, mode: "recovery")
    let rebootLogged = await waitUntil(timeout: 3) {
        model.activities.contains { $0.title == "Device Rebooting" } ||
            model.activities.contains { $0.title.hasPrefix("Rebooting device") }
    }
    #expect(rebootLogged)

    // Test Shutdown Emulator
    model.shutdownEmulator(device: device)
    let shutdownLogged = await waitUntil(timeout: 3) {
        model.activities.contains { $0.title == "Shutting down emulator" }
    }
    #expect(shutdownLogged)

    
    // Test Port Forwarding
    model.configurePortForwarding(device: device)
    let portLogged = await waitUntil(timeout: 3) {
        model.activities.contains { $0.title == "Port rule configured" }
    }
    #expect(portLogged)
    #expect(portForwardPromptCalled)
    
    // Test Mirroring
    ScrcpyLocator.customPath = "/nonexistent/scrcpy"
    model.startMirroring(device: device)
    #expect(model.activities.contains { $0.title == "scrcpy not found" })
    
    // Test Mirroring Successful Path (where scrcpy is located)
    ScrcpyLocator.customPath = "/usr/bin/true"
    defer { ScrcpyLocator.customPath = nil }
    model.startMirroring(device: device)
    #expect(model.activities.contains { $0.title == "Starting screen mirroring" })
    
    try await stopADBBackedServices(model, root: root)
}


@MainActor
private func waitUntil(timeout: TimeInterval, condition: @escaping @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return condition()
}

@MainActor
private func stopADBBackedServices(_ model: DroidScoutModel, root: URL) async throws {
    let failingADB = root.appendingPathComponent("adb-stop-\(UUID().uuidString)")
    try TestSupport.executableScript(failingADB, body: "echo stop >&2; exit 7")
    model.settings.customADBPath = failingADB.pathString
    await model.detectADB()
}
