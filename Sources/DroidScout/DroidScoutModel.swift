import Combine
import Foundation

@MainActor
public final class DroidScoutModel: ObservableObject {
    @Published public var adbStatus: ADBAvailability = .checking
    @Published public var devices: [AndroidDevice] = []
    @Published var selectedSerials: Set<String> = []
    @Published var activities: [ActivityEvent]
    @Published var artifacts: [ArtifactRecord]
    @Published public var installResults: [InstallResult] = []
    @Published var activeLogSessions: [LogSessionManager.Session] = []
    @Published var restartAvailable = false
    @Published var isRefreshingDevices = false
    @Published var isRestartingADBServer = false
    @Published var isPairingDevice = false
    @Published public var settings: AppSettings {
        didSet {
            store.saveSettings(settings)
        }
    }

    private let store: LocalStore
    private let locator = ADBLocator()
    private let tracker = DeviceTracker()
    private let artifactIndexer = ArtifactIndexer()
    private let notificationManager: AppNotificationManager
    private let logSessionManager: LogSessionManager
    private let updateService: UpdateService
    private let chooseADBURLProvider: @MainActor () -> URL?
    private let projectFolderURLsProvider: @MainActor () -> [URL]
    private let installAPKURLsProvider: @MainActor () -> [URL]
    private let textCopier: @MainActor (String) -> Void
    private let shellOpener: @MainActor (String) -> Void
    private let diagnosticsRevealer: @MainActor (URL) -> Void
    private let appBundleURLProvider: @MainActor () -> URL?
    private let restartLauncher: @MainActor (URL) -> Void
    private let appTerminator: @MainActor () -> Void
    private let deployCorrelator = DeployCorrelator()

    private var adbClient: ADBClient?
    private var emulatorService: EmulatorService?
    private var installCoordinator: InstallCoordinator?
    private var packagePoller: PackageStatePoller?
    private var packagePollingTask: Task<Void, Never>?
    private var restartWatcherTask: Task<Void, Never>?
    private let launchExecutableModificationDate: Date?
    private var deviceNameCache: [String: String]
    private var packageSnapshots: [String: PackageSnapshot] = [:]

    public convenience init(systemActions: DroidScoutSystemActions = DroidScoutSystemActions()) {
        self.init(store: LocalStore(), systemActions: systemActions)
    }

    convenience init(store: LocalStore, systemActions: DroidScoutSystemActions = DroidScoutSystemActions()) {
        self.init(
            store: store,
            notificationManager: AppNotificationManager(
                requestAuthorizationHandler: systemActions.notificationAuthorizationRequester,
                deliverNotification: systemActions.notificationDeliverer
            ),
            logSessionManager: LogSessionManager(
                openLogHandler: systemActions.logOpener,
                revealLogsHandler: systemActions.logsRevealer
            ),
            updateService: UpdateService(openHandler: systemActions.updateOpener),
            chooseADBURLProvider: systemActions.chooseADBURLProvider,
            projectFolderURLsProvider: systemActions.projectFolderURLsProvider,
            installAPKURLsProvider: systemActions.installAPKURLsProvider,
            textCopier: systemActions.textCopier,
            shellOpener: systemActions.shellOpener,
            diagnosticsRevealer: systemActions.diagnosticsRevealer,
            appBundleURLProvider: systemActions.appBundleURLProvider,
            restartLauncher: systemActions.restartLauncher,
            appTerminator: systemActions.appTerminator
        )
    }

    init(
        store: LocalStore,
        notificationManager: AppNotificationManager = AppNotificationManager(),
        logSessionManager: LogSessionManager = LogSessionManager(),
        updateService: UpdateService = UpdateService(),
        chooseADBURLProvider: @escaping @MainActor () -> URL? = { nil },
        projectFolderURLsProvider: @escaping @MainActor () -> [URL] = { [] },
        installAPKURLsProvider: @escaping @MainActor () -> [URL] = { [] },
        textCopier: @escaping @MainActor (String) -> Void = { _ in },
        shellOpener: @escaping @MainActor (String) -> Void = { _ in },
        diagnosticsRevealer: @escaping @MainActor (URL) -> Void = { _ in },
        appBundleURLProvider: @escaping @MainActor () -> URL? = { nil },
        restartLauncher: @escaping @MainActor (URL) -> Void = { _ in },
        appTerminator: @escaping @MainActor () -> Void = {}
    ) {
        self.store = store
        self.notificationManager = notificationManager
        self.logSessionManager = logSessionManager
        self.updateService = updateService
        self.chooseADBURLProvider = chooseADBURLProvider
        self.projectFolderURLsProvider = projectFolderURLsProvider
        self.installAPKURLsProvider = installAPKURLsProvider
        self.textCopier = textCopier
        self.shellOpener = shellOpener
        self.diagnosticsRevealer = diagnosticsRevealer
        self.appBundleURLProvider = appBundleURLProvider
        self.restartLauncher = restartLauncher
        self.appTerminator = appTerminator
        launchExecutableModificationDate = Self.executableModificationDate()
        var loadedSettings = store.loadSettings()
        if loadedSettings.logRetentionDays == 14 {
            loadedSettings.logRetentionDays = AppSettings.defaults.logRetentionDays
        }
        settings = loadedSettings
        activities = store.loadActivities()
        artifacts = store.loadArtifacts()
        deviceNameCache = store.loadDeviceNames()

        tracker.onDevicesChanged = { [weak self] devices in
            self?.applyDeviceSnapshot(devices)
        }
        tracker.onWatcherError = { [weak self] message in
            self?.recordActivity(kind: .adb, title: "ADB watcher stopped", detail: message, success: false)
        }
    }

    var onlineDevices: [AndroidDevice] {
        visibleDevices.filter { $0.state == .online }
    }

    public var visibleDevices: [AndroidDevice] {
        devices.filter { !isHidden($0) }
    }

    var hiddenDeviceCount: Int {
        devices.count - visibleDevices.count
    }

    var selectedOnlineDevices: [AndroidDevice] {
        let visibleOnlineDevices = visibleDevices.filter { $0.state == .online }
        let selected = visibleOnlineDevices.filter { selectedSerials.contains($0.serial) }
        return selected.isEmpty ? visibleOnlineDevices : selected
    }

    var recentArtifacts: [ArtifactRecord] {
        artifacts
            .filter(\.isReinstallable)
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    var statusBanner: (title: String, message: String, style: BannerStyle)? {
        if let title = adbStatus.bannerTitle, let message = adbStatus.bannerMessage {
            return (title, message, .error)
        }
        if visibleDevices.contains(where: { $0.state == .unauthorized }) {
            return ("Device authorization needed", "Confirm the RSA prompt on the Android device, then refresh.", .warning)
        }
        if visibleDevices.contains(where: { $0.state == .offline }) {
            return ("Offline device detected", "Reconnect the device or check its USB/Wi-Fi debugging state.", .warning)
        }
        return nil
    }

    public func start() {
        notificationManager.requestAuthorization()
        logSessionManager.pruneLogs(retentionDays: settings.logRetentionDays)
        startRestartWatcher()
        Task {
            await detectADB()
            await scanProjects()
        }
    }

    func detectADB() async {
        adbStatus = .checking
        stopADBBackedServices()
        let availability = await locator.locate(customPath: settings.customADBPath)
        adbStatus = availability

        guard case let .healthy(path, _) = availability else {
            recordActivity(
                kind: .adb,
                title: "ADB setup needed",
                detail: availability.bannerMessage ?? "ADB could not be found.",
                success: false
            )
            return
        }

        let client = ADBClient(adbPath: path)
        let emulatorService = EmulatorService(adbPath: path)
        adbClient = client
        self.emulatorService = emulatorService
        let coordinator = InstallCoordinator(adbClient: client)
        coordinator.onResultChanged = { [weak self] result in
            self?.upsertInstallResult(result)
        }
        installCoordinator = coordinator
        packagePoller = PackageStatePoller(adbClient: client)
        tracker.start(adbClient: client, emulatorService: emulatorService, cachedNames: deviceNameCache, interval: settings.packagePollingInterval)
        startPackagePolling()
    }

    func retryADBDetection() {
        Task { await detectADB() }
    }

    func clearCustomADBPathAndRetry() {
        settings.customADBPath = nil
        retryADBDetection()
    }

    func restartADBServer() {
        guard !isRestartingADBServer else { return }
        guard let adbClient else {
            recordActivity(kind: .adb, title: "ADB restart unavailable", detail: "ADB is not currently available.", success: false)
            return
        }

        isRestartingADBServer = true
        recordActivity(kind: .adb, title: "Restarting ADB server", detail: "Running adb kill-server and start-server.", success: nil)

        Task {
            let killResult = await adbClient.run(arguments: ["kill-server"], timeout: 10)
            let startResult = killResult.succeeded
                ? await adbClient.run(arguments: ["start-server"], timeout: 15)
                : killResult
            let succeeded = killResult.succeeded && startResult.succeeded
            let detail = startResult.stderr.nilIfBlank
                ?? startResult.stdout.nilIfBlank
                ?? (succeeded ? "ADB server restarted." : "ADB server restart failed.")

            recordActivity(
                kind: .adb,
                title: succeeded ? "ADB server restarted" : "ADB server restart failed",
                detail: detail,
                success: succeeded
            )
            await detectADB()
            isRestartingADBServer = false
        }
    }

    func pairAndroidDevice(address: String, pairingCode: String) {
        guard !isPairingDevice else { return }
        guard let adbClient else {
            recordActivity(kind: .adb, title: "Pairing unavailable", detail: "ADB is not currently available.", success: false)
            return
        }

        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidPairingAddress(trimmedAddress), !trimmedCode.isEmpty else {
            recordActivity(kind: .adb, title: "Pairing details needed", detail: "Enter the Android device pairing address and pairing code.", success: false)
            return
        }

        isPairingDevice = true
        recordActivity(kind: .adb, title: "Pairing Android device", detail: trimmedAddress, success: nil)

        Task {
            let result = await adbClient.pair(address: trimmedAddress, pairingCode: trimmedCode)
            let output = result.stderr.nilIfBlank ?? result.stdout.nilIfBlank
            let detail = Self.redactPairingCode(output ?? (result.succeeded ? "Device paired." : "Pairing failed."), pairingCode: trimmedCode)
            recordActivity(
                kind: .adb,
                title: result.succeeded ? "Android device paired" : "Android pairing failed",
                detail: detail,
                success: result.succeeded
            )
            await tracker.refresh()
            isPairingDevice = false
        }
    }

    func chooseADB() {
        chooseADB(url: chooseADBURLProvider())
    }

    func chooseADB(url: URL?) {
        guard let url else { return }
        settings.customADBPath = url.pathString
        Task { await detectADB() }
    }

    func refreshDevices() {
        guard !isRefreshingDevices else { return }
        isRefreshingDevices = true
        Task {
            await tracker.refresh()
            await pollPackageState()
            try? await Task.sleep(nanoseconds: 450_000_000)
            isRefreshingDevices = false
        }
    }

    func addProjectFolder() {
        addProjectFolders(projectFolderURLsProvider())
    }

    func addProjectFolders(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var paths = settings.watchedProjectPaths
        for url in urls {
            let path = url.pathString
            if !paths.contains(path) {
                paths.append(path)
            }
        }
        settings.watchedProjectPaths = paths.sorted()
        Task { await scanProjects() }
    }

    func removeProjectFolder(_ path: String) {
        settings.watchedProjectPaths.removeAll { $0 == path }
        Task { await scanProjects() }
    }

    func scanProjects() async {
        let indexed = await artifactIndexer.indexProjects(paths: settings.watchedProjectPaths)
        let persistedRecents = artifacts.filter { $0.source == .droidScout || $0.source == .external }
        artifacts = mergeArtifacts(persistedRecents + indexed)
        store.saveArtifacts(artifacts)
        recordActivity(
            kind: .deploy,
            title: "Project artifacts indexed",
            detail: indexed.isEmpty ? "No APK or AAB outputs found." : "Found \(indexed.count) build artifact\(indexed.count == 1 ? "" : "s").",
            success: true
        )
        await pollPackageState()
    }

    func scanProjectsFromUI() {
        Task { await scanProjects() }
    }

    func installAPKFromPanel(preselectedSerial: String? = nil) {
        installAPK(urls: installAPKURLsProvider(), preselectedSerial: preselectedSerial)
    }

    func installAPKFromMainAction() {
        installAPKFromPanel()
    }

    func installAPK(urls: [URL], preselectedSerial: String? = nil) {
        guard !urls.isEmpty else { return }

        if urls.contains(where: { $0.pathExtension.lowercased() == "aab" }) {
            recordActivity(kind: .install, title: "AAB not installable", detail: "AAB files are shown for awareness but cannot be installed in v1.", success: false)
            return
        }

        let artifact = artifactForInstall(paths: urls.map(\.pathString))
        let targetDevices: [AndroidDevice]
        if let preselectedSerial, let device = devices.first(where: { $0.serial == preselectedSerial }) {
            targetDevices = [device]
        } else {
            targetDevices = selectedOnlineDevices
        }
        Task { await install(artifact: artifact, devices: targetDevices) }
    }

    func reinstallRecent(_ artifact: ArtifactRecord) {
        guard artifact.isReinstallable else {
            recordActivity(kind: .install, title: "Artifact not installable", detail: "\(artifact.displayName) cannot be installed by Droid Scout.", success: false)
            return
        }

        let previousDeviceSerials = Set(artifact.devices)
        let defaultDevices = onlineDevices.filter { previousDeviceSerials.contains($0.serial) }
        let targets = selectedSerials.isEmpty ? (defaultDevices.isEmpty ? onlineDevices : defaultDevices) : selectedOnlineDevices
        Task { await install(artifact: artifact, devices: targets) }
    }

    func startLogsForSelected() {
        guard case let .healthy(path, _) = adbStatus else { return }
        for device in selectedOnlineDevices {
            do {
                let session = try logSessionManager.startLogStream(device: device, adbPath: path, target: settings.logTarget)
                activeLogSessions = logSessionManager.sessions
                recordActivity(
                    kind: .log,
                    title: "Log stream started",
                    detail: "\(device.friendlyName) -> \(session.fileURL.lastPathComponent)",
                    deviceSerials: [device.serial],
                    success: true
                )
            } catch {
                recordActivity(
                    kind: .log,
                    title: "Log stream failed",
                    detail: error.localizedDescription,
                    deviceSerials: [device.serial],
                    success: false
                )
            }
        }
    }

    func stopLogSession(_ session: LogSessionManager.Session) {
        logSessionManager.stop(session)
        activeLogSessions = logSessionManager.sessions
    }

    func clearLogcatForSelected() {
        guard let adbClient else { return }
        for device in selectedOnlineDevices {
            Task {
                let result = await adbClient.run(serial: device.serial, arguments: ["logcat", "-c"], timeout: 15)
                recordActivity(
                    kind: .log,
                    title: result.succeeded ? "Logcat buffer cleared" : "Could not clear logcat buffer",
                    detail: device.friendlyName,
                    deviceSerials: [device.serial],
                    success: result.succeeded
                )
            }
        }
    }

    func openShell(device: AndroidDevice) {
        guard let command = shellCommand(device: device) else { return }
        shellOpener(command)
    }

    func shellCommand(device: AndroidDevice) -> String? {
        guard case let .healthy(path, _) = adbStatus else { return nil }
        return "\(path.shellEscaped) -s \(device.serial.shellEscaped) shell"
    }

    func copySerial(_ device: AndroidDevice) {
        textCopier(device.serial)
        recordActivity(kind: .device, title: "Serial copied", detail: device.shortSerial, deviceSerials: [device.serial], success: true)
    }

    func copyHomebrewInstallHint() {
        textCopier("brew install android-platform-tools")
    }

    func hideDevice(_ device: AndroidDevice) {
        let identity = device.hiddenIdentity
        if !settings.hiddenDeviceIdentities.contains(identity) {
            settings.hiddenDeviceIdentities.append(identity)
            settings.hiddenDeviceIdentities.sort()
        }
        selectedSerials.remove(device.serial)
        recordActivity(kind: .device, title: "Device hidden", detail: device.friendlyName, deviceSerials: [device.serial], success: true)
    }

    func showHiddenDevices() {
        guard !settings.hiddenDeviceIdentities.isEmpty else { return }
        settings.hiddenDeviceIdentities = []
        recordActivity(kind: .device, title: "Hidden devices shown", detail: "All devices and emulators are visible again.", success: true)
    }

    func startEmulator(device: AndroidDevice) {
        guard let avdName = device.avdName else { return }
        guard let emulatorService, emulatorService.isAvailable else {
            recordActivity(
                kind: .adb,
                title: "Emulator start failed",
                detail: "The Android Emulator tool was not found in the detected SDK.",
                deviceSerials: [device.serial],
                success: false
            )
            return
        }

        do {
            try emulatorService.startAVD(named: avdName)
            recordActivity(
                kind: .device,
                title: "Emulator starting",
                detail: avdName,
                deviceSerials: [device.serial],
                success: true
            )
            Task {
                try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
                await tracker.refresh()
            }
        } catch {
            recordActivity(
                kind: .adb,
                title: "Emulator start failed",
                detail: error.localizedDescription,
                deviceSerials: [device.serial],
                success: false
            )
        }
    }

    func revealLogs() {
        logSessionManager.revealLogsFolder()
    }

    func checkForUpdates() {
        updateService.checkForUpdates()
        recordActivity(kind: .update, title: "Checking for updates", detail: "Opened GitHub Releases.", success: true)
    }

    func restartToApplyUpdate() {
        guard let bundleURL = appBundleURLProvider() else {
            recordActivity(kind: .update, title: "Restart unavailable", detail: "Droid Scout is not running from an app bundle.", success: false)
            return
        }

        recordActivity(kind: .update, title: "Restarting Droid Scout", detail: "Launching the installed app bundle.", success: true)
        tracker.stop()
        logSessionManager.stopAll()
        restartWatcherTask?.cancel()
        restartLauncher(bundleURL)
        appTerminator()
    }

    func exportDiagnostics() {
        do {
            let url = try store.exportDiagnostics(settings: settings, devices: devices, activities: activities, artifacts: artifacts)
            diagnosticsRevealer(url)
            recordActivity(kind: .adb, title: "Diagnostics exported", detail: url.lastPathComponent, success: true)
        } catch {
            recordActivity(kind: .adb, title: "Diagnostics export failed", detail: error.localizedDescription, success: false)
        }
    }

    func quit() {
        restartWatcherTask?.cancel()
        tracker.stop()
        logSessionManager.stopAll()
        appTerminator()
    }

    private func startRestartWatcher() {
        restartWatcherTask?.cancel()
        restartWatcherTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshRestartAvailability()
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            }
        }
    }

    private func refreshRestartAvailability() {
        guard let launchExecutableModificationDate,
              let currentExecutableModificationDate = Self.executableModificationDate()
        else {
            restartAvailable = false
            return
        }

        restartAvailable = currentExecutableModificationDate.timeIntervalSince(launchExecutableModificationDate) > 1
    }

    private static func executableModificationDate() -> Date? {
        guard let executableURL = Bundle.main.executableURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: executableURL.pathString)
        else { return nil }
        return attributes[.modificationDate] as? Date
    }

    private static func isValidPairingAddress(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let port = parts.last,
              Int(port).map({ (1...65_535).contains($0) }) == true
        else { return false }
        return parts.dropLast().joined(separator: ":").nilIfBlank != nil
    }

    private static func redactPairingCode(_ text: String, pairingCode: String) -> String {
        text.replacingOccurrences(of: pairingCode, with: "[code]")
    }

    private func stopADBBackedServices() {
        packagePollingTask?.cancel()
        packagePollingTask = nil
        tracker.stop()
        adbClient = nil
        emulatorService = nil
        installCoordinator = nil
        packagePoller = nil
    }

    private func startPackagePolling() {
        packagePollingTask?.cancel()
        packagePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollPackageState()
                let seconds = UInt64(max(self.settings.packagePollingInterval, 10) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: seconds)
            }
        }
    }

    private func pollPackageState() async {
        guard let packagePoller else { return }
        let packageIDs = Set(artifacts.compactMap(\.packageName))
        guard !packageIDs.isEmpty else { return }
        let snapshots = await packagePoller.snapshots(for: packageIDs, devices: onlineDevices)
        applyPackageSnapshots(snapshots)
    }

    func applyPackageSnapshots(_ snapshots: [PackageSnapshot]) {
        for snapshot in snapshots {
            let key = "\(snapshot.deviceSerial)|\(snapshot.packageName)"
            if let previous = packageSnapshots[key],
               previous.versionCode != snapshot.versionCode ||
                previous.versionName != snapshot.versionName ||
                previous.lastUpdateTime != snapshot.lastUpdateTime {
                handlePackageChange(snapshot)
            }
            packageSnapshots[key] = snapshot
        }
    }

    func handlePackageChange(_ snapshot: PackageSnapshot) {
        let correlation = deployCorrelator.correlate(snapshot: snapshot, artifacts: artifacts)
        let deviceName = devices.first(where: { $0.serial == snapshot.deviceSerial })?.friendlyName ?? snapshot.deviceSerial

        if var artifact = correlation.artifact {
            artifact.id = UUID()
            artifact.lastSeen = Date()
            artifact.devices = Array(Set(artifact.devices + [snapshot.deviceSerial])).sorted()
            artifact.source = .external
            artifact.confidence = correlation.confidence
            artifact.evidence = correlation.evidence
            artifacts = mergeArtifacts([artifact] + artifacts)
            store.saveArtifacts(artifacts)
        }

        let detail = "\(snapshot.packageName) changed on \(deviceName). \(correlation.evidence)"
        recordActivity(kind: .deploy, title: "External deploy detected", detail: detail, deviceSerials: [snapshot.deviceSerial], success: true)

        if correlation.confidence >= settings.confidenceThreshold {
            notificationManager.notify(
                kind: .deploy,
                title: "External deploy detected",
                body: detail,
                mode: settings.notificationMode,
                key: "deploy|\(snapshot.deviceSerial)|\(snapshot.packageName)|\(snapshot.versionCode ?? "")"
            )
        }
    }

    func install(artifact: ArtifactRecord, devices targetDevices: [AndroidDevice]) async {
        guard let installCoordinator else {
            recordActivity(kind: .install, title: "Install unavailable", detail: "ADB is not currently available.", success: false)
            return
        }
        guard artifact.isReinstallable else {
            recordActivity(kind: .install, title: "Artifact not installable", detail: "\(artifact.displayName) cannot be installed by Droid Scout.", success: false)
            return
        }
        let missingPaths = artifact.paths.filter { !FileManager.default.fileExists(atPath: $0) }
        guard missingPaths.isEmpty else {
            let missingNames = missingPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
            recordActivity(kind: .install, title: "Artifact unavailable", detail: "Missing file\(missingPaths.count == 1 ? "" : "s"): \(missingNames)", success: false)
            return
        }
        guard !targetDevices.isEmpty else {
            recordActivity(kind: .install, title: "No online devices selected", detail: "Select one or more online devices before installing.", success: false)
            return
        }

        let targetSummary = "\(targetDevices.count) device\(targetDevices.count == 1 ? "" : "s")"
        recordActivity(kind: .install, title: "Install started", detail: "\(artifact.displayName) on \(targetSummary).", deviceSerials: targetDevices.map(\.serial), success: nil)

        var artifact = artifact
        artifact.lastSeen = Date()
        artifact.source = .droidScout
        artifact.devices = targetDevices.map(\.serial)

        let results = await installCoordinator.install(artifact: artifact, devices: targetDevices)
        for result in results {
            artifact.perDeviceResults[result.deviceSerial] = result.status.displayName
        }
        artifacts = mergeArtifacts([artifact] + artifacts)
        store.saveArtifacts(artifacts)

        let successes = results.filter { $0.status == .success }.count
        let failures = results.filter { $0.status == .failed }.count
        let skipped = results.filter { $0.status == .skipped }.count
        let detail = "Installed on \(successes) of \(results.count) device\(results.count == 1 ? "" : "s"). \(failures) failed, \(skipped) skipped."
        recordActivity(kind: .install, title: failures == 0 ? "Install completed" : "Install completed with failures", detail: detail, deviceSerials: targetDevices.map(\.serial), success: failures == 0)

        if failures > 0 || settings.notificationMode == .full {
            notificationManager.notify(
                kind: .install,
                title: failures == 0 ? "Install completed" : "Install failed",
                body: detail,
                mode: settings.notificationMode,
                key: "install|\(artifact.id.uuidString)|\(successes)|\(failures)"
            )
        }

        await pollPackageState()
    }

    func artifactForInstall(paths: [String]) -> ArtifactRecord {
        if let existing = artifacts.first(where: { Set($0.paths) == Set(paths) }) {
            var record = existing
            record.id = UUID()
            record.source = .droidScout
            record.lastSeen = Date()
            return record
        }
        let metadata = paths.first.flatMap { APKMetadataReader.read(path: $0) }

        return ArtifactRecord(
            id: UUID(),
            paths: paths,
            packageName: metadata?.packageName,
            versionName: metadata?.versionName,
            versionCode: metadata?.versionCode,
            variant: nil,
            kind: paths.count > 1 ? .splitAPK : .apk,
            lastSeen: Date(),
            source: .droidScout,
            confidence: nil,
            devices: [],
            perDeviceResults: [:],
            evidence: metadata == nil ? "Chosen manually; APK metadata was not available." : "Chosen manually; APK metadata parsed."
        )
    }

    func mergeArtifacts(_ records: [ArtifactRecord]) -> [ArtifactRecord] {
        var merged: [String: ArtifactRecord] = [:]
        for record in records {
            let key = record.paths.sorted().joined(separator: "|")
            if let existing = merged[key] {
                var newest = existing.lastSeen >= record.lastSeen ? existing : record
                newest.devices = Array(Set(existing.devices + record.devices)).sorted()
                var perDeviceResults = existing.perDeviceResults
                perDeviceResults.merge(record.perDeviceResults) { _, new in new }
                newest.perDeviceResults = perDeviceResults
                if newest.packageName == nil { newest.packageName = existing.packageName ?? record.packageName }
                merged[key] = newest
            } else {
                merged[key] = record
            }
        }
        return merged.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    func applyDeviceSnapshot(_ snapshot: [AndroidDevice]) {
        let previousBySerial = Dictionary(uniqueKeysWithValues: devices.map { ($0.serial, $0) })
        let previousSerials = Set(previousBySerial.keys)
        let snapshotSerials = Set(snapshot.map(\.serial))
        let retainedDevices = previousBySerial.values.compactMap { previous -> AndroidDevice? in
            guard !previous.isEmulator, !snapshotSerials.contains(previous.serial) else {
                return nil
            }

            var retained = previous
            retained.state = .offline
            retained.transportHint = previous.transportHint ?? "Last seen"
            return retained
        }
        let nextDevices = sortDevices(snapshot + retainedDevices)
        let currentSerials = Set(nextDevices.map(\.serial))

        for device in snapshot {
            if device.state == .online {
                deviceNameCache[device.serial] = device.friendlyName
            }
        }
        store.saveDeviceNames(deviceNameCache)
        tracker.updateCachedNames(deviceNameCache)

        devices = nextDevices
        let visibleSerials = Set(visibleDevices.map(\.serial))
        let onlineSerials = Set(visibleDevices.filter { $0.state == .online }.map(\.serial))
        selectedSerials = selectedSerials.intersection(currentSerials).intersection(visibleSerials)
        if selectedSerials.isEmpty {
            selectedSerials = onlineSerials
        }

        for serial in currentSerials.subtracting(previousSerials) {
            guard let device = snapshot.first(where: { $0.serial == serial }) else { continue }
            if device.state == .stopped || isHidden(device) {
                continue
            }
            recordActivity(kind: .device, title: "Device connected", detail: "\(device.friendlyName) (\(device.state.displayName))", deviceSerials: [serial], success: device.state == .online)
            if device.state == .unauthorized {
                notificationManager.notify(kind: .adb, title: "Device unauthorized", body: "Authorize \(device.friendlyName) on the device.", mode: settings.notificationMode, key: "unauthorized|\(serial)")
            } else {
                notificationManager.notify(kind: .device, title: "Device connected", body: device.friendlyName, mode: settings.notificationMode, key: "connect|\(serial)")
            }
        }

        for serial in previousSerials.subtracting(currentSerials) {
            guard let previous = previousBySerial[serial] else { continue }
            let name = previous.friendlyName
            if previous.state == .stopped || isHidden(previous) {
                continue
            }
            recordActivity(kind: .device, title: "Device disconnected", detail: name, deviceSerials: [serial], success: nil)
            notificationManager.notify(kind: .device, title: "Device disconnected", body: name, mode: settings.notificationMode, key: "disconnect|\(serial)")
        }
    }

    private func upsertInstallResult(_ result: InstallResult) {
        installResults.removeAll { $0.id == result.id }
        installResults.insert(result, at: 0)
        installResults = Array(installResults.prefix(40))
    }

    func clearCompletedInstallResults() {
        installResults.removeAll { result in
            switch result.status {
            case .success, .failed, .skipped:
                return true
            case .queued, .installing:
                return false
            }
        }
    }

    private func recordActivity(
        kind: ActivityKind,
        title: String,
        detail: String,
        deviceSerials: [String] = [],
        success: Bool? = nil
    ) {
        activities.insert(ActivityEvent(
            id: UUID(),
            timestamp: Date(),
            kind: kind,
            title: title,
            detail: detail,
            deviceSerials: deviceSerials,
            success: success
        ), at: 0)
        activities = Array(activities.prefix(80))
        store.saveActivities(activities)
    }

    private func isHidden(_ device: AndroidDevice) -> Bool {
        settings.hiddenDeviceIdentities.contains(device.hiddenIdentity)
    }

    private func sortDevices(_ devices: [AndroidDevice]) -> [AndroidDevice] {
        devices.sorted {
            if deviceStateRank($0.state) != deviceStateRank($1.state) {
                return deviceStateRank($0.state) < deviceStateRank($1.state)
            }
            return $0.friendlyName.localizedCaseInsensitiveCompare($1.friendlyName) == .orderedAscending
        }
    }

    private func deviceStateRank(_ state: DeviceConnectionState) -> Int {
        switch state {
        case .online: 0
        case .unauthorized: 1
        case .offline: 2
        case .stopped: 3
        case .unknown: 4
        }
    }
}

enum BannerStyle {
    case warning
    case error
}
