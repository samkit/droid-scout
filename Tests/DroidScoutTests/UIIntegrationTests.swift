import AppKit
import SwiftUI
import Testing
@testable import DroidScout

@MainActor
@Test func settingsAndInstallProgressRenderEveryPaneInMacWindows() async throws {
    guard ProcessInfo.processInfo.environment["DROID_SCOUT_UI_TESTS"] == "1" else {
        return
    }

    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(root) }
    let model = makePopulatedUIModel(root: root)
    model.adbStatus = .failed(path: "/tmp/adb", message: "ADB exited with status 1.")
    model.settings.customADBPath = "/tmp/custom-adb"
    model.settings.watchedProjectPaths = [
        root.appendingPathComponent("ProjectOne", isDirectory: true).pathString,
        root.appendingPathComponent("ProjectTwo", isDirectory: true).pathString
    ]

    for tab in SettingsTab.allCases {
        let pane = RenderedWindow(
            DroidScoutSettingsPaneView(model: model, tab: tab)
                .padding(20)
                .frame(width: 680, height: 500),
            size: NSSize(width: 680, height: 500)
        )
        await pane.settle()
        #expect(pane.distinctRenderedColorCount() >= 8)
        pane.close()
        #expect(tab.id == tab.rawValue)
    }

    let tabShell = RenderedWindow(
        DroidScoutSettingsView(model: model, initialTab: .adb),
        size: NSSize(width: 680, height: 500)
    )
    await tabShell.settle()
    #expect(tabShell.distinctRenderedColorCount() > 8)
    tabShell.close()

    let emptySettings = makePopulatedUIModel(root: root.appendingPathComponent("EmptySettings", isDirectory: true))
    emptySettings.adbStatus = .healthy(path: "/tmp/adb", version: "35.0.2")
    emptySettings.settings.customADBPath = nil
    emptySettings.settings.watchedProjectPaths = []
    emptySettings.artifacts = []
    emptySettings.restartAvailable = false
    for tab in [SettingsTab.adb, .projects, .updates] {
        let pane = RenderedWindow(
            DroidScoutSettingsPaneView(model: emptySettings, tab: tab)
                .padding(20)
                .frame(width: 680, height: 500),
            size: NSSize(width: 680, height: 500)
        )
        await pane.settle()
        #expect(pane.distinctRenderedColorCount() >= 8)
        pane.close()
    }

    await exercisePopoverBodies(root: root)
    verifyStatusBarPresentationReflectsDeviceAndADBState()

    let progress = RenderedWindow(
        DroidScoutInstallProgressView(model: model),
        size: NSSize(width: 680, height: 460)
    )
    await progress.settle()

    #expect(progress.distinctRenderedColorCount() > 12)
    #expect(model.installResults.filter { !$0.status.isTerminal }.count == 2)
    #expect(model.installResults.filter(\.status.isTerminal).count == 3)
    progress.close()

    let completedOnly = makePopulatedUIModel(root: root.appendingPathComponent("CompletedInstalls", isDirectory: true))
    completedOnly.installResults = [
        installResult(name: "DoneApp", status: .success, stdout: "Success"),
        installResult(name: "SkippedApp", status: .skipped, stderr: "Skipped")
    ]
    let completedProgress = RenderedWindow(
        DroidScoutInstallProgressView(model: completedOnly),
        size: NSSize(width: 680, height: 460)
    )
    await completedProgress.settle()
    #expect(completedProgress.distinctRenderedColorCount() > 8)
    completedProgress.close()

    let idleProgressModel = makePopulatedUIModel(root: root.appendingPathComponent("IdleInstalls", isDirectory: true))
    idleProgressModel.installResults = []
    let idleProgress = RenderedWindow(
        DroidScoutInstallProgressView(model: idleProgressModel),
        size: NSSize(width: 680, height: 460)
    )
    await idleProgress.settle()
    #expect(idleProgress.distinctRenderedColorCount() > 8)
    idleProgress.close()
    await settleMacUI()
}

@MainActor
@Test func renderedMacControlsInvokeRealModelActionsWithInjectedSystemBoundaries() async throws {
    guard ProcessInfo.processInfo.environment["DROID_SCOUT_UI_TESTS"] == "1" else {
        return
    }

    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(root) }
    let model = makePopulatedUIModel(root: root)

    var capturedMenu: NSMenu?
    var capturedMenuSource: NSView?
    var expanded = false
    let footerTop = FooterMenuListView(
        model: model,
        section: .top,
        isRecentActivityExpanded: Binding(get: { expanded }, set: { expanded = $0 }),
        menuPresenter: { menu, sourceView in
            capturedMenu = menu
            capturedMenuSource = sourceView
        }
    )
    let footerTopRender = RenderedWindow(footerTop.frame(width: 362, height: 84), size: NSSize(width: 362, height: 84))
    await footerTopRender.settle()
    let topRows = footerTopRender.views(of: CodexStyleMenuRowView.self)
    #expect(topRows.count == 3)
    guard topRows.count == 3 else {
        footerTopRender.close()
        return
    }
    topRows[0].mouseDown(with: mouseEvent(location: NSPoint(x: 4, y: 4)))
    #expect(model.activities.first?.title == "Restarting Droid Scout")
    topRows[1].mouseDown(with: mouseEvent(location: NSPoint(x: 4, y: 4)))
    #expect(capturedMenu?.title == "Advanced")
    #expect(capturedMenuSource != nil)
    (capturedMenu?.items.first as? ClosureMenuItem)?.performHandler()
    #expect(model.activities.contains { $0.title == "ADB restart unavailable" || $0.title == "Restarting ADB server" })
    topRows[2].mouseDown(with: mouseEvent(location: NSPoint(x: 4, y: 4)))
    #expect(expanded)
    footerTopRender.close()

    let footerBottom = FooterMenuListView(
        model: model,
        section: .bottom,
        isRecentActivityExpanded: .constant(false),
        menuPresenter: { _, _ in }
    )
    let footerBottomRender = RenderedWindow(footerBottom.frame(width: 362, height: 84), size: NSSize(width: 362, height: 84))
    await footerBottomRender.settle()
    for row in footerBottomRender.views(of: CodexStyleMenuRowView.self) {
        row.mouseDown(with: mouseEvent(location: NSPoint(x: 4, y: 4)))
    }
    #expect(model.activities.contains { $0.title == "Checking for updates" })
    footerBottomRender.close()

    await settleMacUI()
}

@MainActor
@Test func statusItemPresenterReflectsDeviceAndADBState() {
    verifyStatusBarPresentationReflectsDeviceAndADBState()
}

@MainActor
@Test func popoverNativeControlsHandleAppKitEventsAndMenus() throws {
    guard ProcessInfo.processInfo.environment["DROID_SCOUT_UI_TESTS"] == "1" else {
        return
    }

    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(root) }
    let model = makePopulatedUIModel(root: root)
    model.adbStatus = .missing(message: "ADB not configured")

    var rowWasClicked = false
    let row = CodexStyleMenuRowView(title: "Action", showsSubmenuIndicator: true, isExpanded: true) { sourceView in
        rowWasClicked = sourceView is CodexStyleMenuRowView
    }
    row.frame = NSRect(x: 0, y: 0, width: 220, height: 28)
    row.updateTrackingAreas()
    row.updateTrackingAreas()
    row.mouseEntered(with: mouseEvent(location: NSPoint(x: 5, y: 5)))
    row.draw(row.bounds)
    row.mouseDown(with: mouseEvent(location: NSPoint(x: 5, y: 5)))
    row.mouseUp(with: mouseEvent(location: NSPoint(x: 300, y: 300)))
    row.mouseExited(with: mouseEvent(location: NSPoint(x: 300, y: 300)))
    #expect(rowWasClicked)

    var menuItemWasInvoked = false
    let item = ClosureMenuItem(title: "Invoke", enabled: false) {
        menuItemWasInvoked = true
    }
    #expect(item.title == "Invoke")
    #expect(!item.isEnabled)
    item.performHandler()
    #expect(menuItemWasInvoked)

    let scrollView = NSScrollView()
    let configuredView = NSView(frame: .zero)
    scrollView.addSubview(configuredView)
    let configurator = ScrollViewConfigurator()
    configurator.configureEnclosingScrollView(from: configuredView)
    #expect(!scrollView.drawsBackground)
    #expect(scrollView.scrollerStyle == .overlay)

    let stopped = TestSupport.device(serial: "avd:Pixel", state: .stopped, friendlyName: "Pixel", avdName: "Pixel")
    var shownDeviceMenu: NSMenu?
    let coordinator = DeviceActionsMenuButton.Coordinator(device: stopped, model: model) { menu, _ in
        shownDeviceMenu = menu
    }
    let stoppedMenu = coordinator.makeMenu()
    #expect(stoppedMenu.items.map(\.title).contains("Start Emulator"))
    #expect(stoppedMenu.items.first { $0.title == "Install APK..." }?.isEnabled == false)
    coordinator.showMenu(NSButton(frame: NSRect(x: 0, y: 0, width: 30, height: 30)))
    #expect(shownDeviceMenu?.items.map(\.title).contains("Start Emulator") == true)
    coordinator.startEmulator()
    #expect(model.activities.first?.title == "Emulator start failed")

    let online = TestSupport.device(serial: "USB-MENU", state: .online, friendlyName: "Menu Pixel")
    coordinator.device = online
    let onlineMenu = coordinator.makeMenu()
    #expect(!onlineMenu.items.map(\.title).contains("Start Emulator"))
    #expect(onlineMenu.items.first { $0.title == "Install APK..." }?.isEnabled == true)
    coordinator.copySerial()
    #expect(model.activities.first?.title == "Serial copied")
    coordinator.openLogStream()
    #expect(model.selectedSerials == ["USB-MENU"])
    coordinator.clearLogcatBuffer()
    #expect(model.selectedSerials == ["USB-MENU"])
    coordinator.hideFromList()
    #expect(model.settings.hiddenDeviceIdentities.contains("USB-MENU"))
    coordinator.installAPK()
    coordinator.openShell()

    model.activities = []
    model.activeLogSessions = []
    #expect(RecentActivityInlineView.height(model: model) == 62)
    model.activities = [
        ActivityEvent(id: UUID(), timestamp: Date(), kind: .adb, title: "Pending", detail: "No result", deviceSerials: [], success: nil)
    ]
    #expect(RecentActivityInlineView.height(model: model) >= 44)
}

@MainActor
private func exercisePopoverBodies(root: URL) async {
    let icon = NSImage(size: NSSize(width: 18, height: 18))
    icon.lockFocus()
    NSColor.systemGreen.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 18, height: 18)).fill()
    icon.unlockFocus()
    icon.setName(NSImage.Name("AndroidStatusIcon"))

    let populated = makePopulatedUIModel(root: root.appendingPathComponent("Popover", isDirectory: true))
    var openedSettings = false
    var openedInstallProgress = false
    let populatedRender = RenderedWindow(
        DroidScoutPopoverView(
            model: populated,
            openSettings: { openedSettings = true },
            openInstallProgress: { openedInstallProgress = true }
        ),
        size: NSSize(width: 390, height: 650)
    )
    await populatedRender.settle()
    #expect(populatedRender.distinctRenderedColorCount() > 12)
    populatedRender.close()

    _ = DroidScoutPopoverView(
        model: populated,
        openSettings: {},
        openInstallProgress: {}
    )
    .body
    #expect(populated.statusBanner?.title == "Device authorization needed")
    #expect(populated.visibleDevices.contains { $0.friendlyName == "Pixel 8" })
    #expect(!openedSettings)
    #expect(!openedInstallProgress)

    icon.setName(nil)
    let fallbackIconModel = makePopulatedUIModel(root: root.appendingPathComponent("FallbackIconPopover", isDirectory: true))
    fallbackIconModel.restartAvailable = false
    let fallbackIconRender = RenderedWindow(
        DroidScoutPopoverView(model: fallbackIconModel, openSettings: {}, openInstallProgress: {}),
        size: NSSize(width: 390, height: 560)
    )
    await fallbackIconRender.settle()
    #expect(fallbackIconRender.distinctRenderedColorCount() > 8)
    fallbackIconRender.close()

    populated.devices = [
        TestSupport.device(serial: "USB-OFF", state: .offline, friendlyName: "Offline Pixel")
    ]
    let offlineRender = RenderedWindow(
        DroidScoutPopoverView(model: populated, openSettings: {}, openInstallProgress: {}),
        size: NSSize(width: 390, height: 560)
    )
    await offlineRender.settle()
    #expect(offlineRender.distinctRenderedColorCount() > 8)
    offlineRender.close()
    #expect(populated.statusBanner?.title == "Offline device detected")

    let missingADB = makePopulatedUIModel(root: root.appendingPathComponent("MissingADBPopover", isDirectory: true))
    missingADB.adbStatus = .missing(message: "Install Android platform-tools.")
    missingADB.devices = []
    missingADB.activities = []
    missingADB.artifacts = []
    missingADB.activeLogSessions = []
    missingADB.restartAvailable = false
    let missingRender = RenderedWindow(
        DroidScoutPopoverView(model: missingADB, openSettings: {}, openInstallProgress: {}),
        size: NSSize(width: 390, height: 560)
    )
    await missingRender.settle()
    #expect(missingRender.distinctRenderedColorCount() > 8)
    missingRender.close()
    #expect(missingADB.statusBanner?.title == "ADB was not found")
    #expect(missingADB.visibleDevices.isEmpty)

    let checking = makePopulatedUIModel(root: root.appendingPathComponent("CheckingPopover", isDirectory: true))
    checking.adbStatus = .checking
    checking.devices = []
    checking.restartAvailable = false
    checking.activities = [
        ActivityEvent(id: UUID(), timestamp: Date(), kind: .adb, title: "Pending", detail: "Still running", deviceSerials: [], success: nil)
    ]
    let checkingRender = RenderedWindow(
        DroidScoutPopoverView(model: checking, openSettings: {}, openInstallProgress: {}),
        size: NSSize(width: 390, height: 520)
    )
    await checkingRender.settle()
    #expect(checkingRender.distinctRenderedColorCount() > 8)
    checkingRender.close()
    #expect(checking.statusBanner == nil)

    let failed = makePopulatedUIModel(root: root.appendingPathComponent("FailedPopover", isDirectory: true))
    failed.adbStatus = .failed(path: "/tmp/adb", message: "ADB failed")
    failed.devices = []
    failed.restartAvailable = false
    let failedRender = RenderedWindow(
        DroidScoutPopoverView(model: failed, openSettings: {}, openInstallProgress: {}),
        size: NSSize(width: 390, height: 520)
    )
    await failedRender.settle()
    #expect(failedRender.distinctRenderedColorCount() > 8)
    failedRender.close()
    #expect(failed.statusBanner?.title == "ADB is not working")

    let allHidden = makePopulatedUIModel(root: root.appendingPathComponent("AllHiddenPopover", isDirectory: true))
    allHidden.devices = [
        TestSupport.device(serial: "USB-HIDDEN", state: .online, friendlyName: "Hidden Pixel")
    ]
    allHidden.settings.hiddenDeviceIdentities = ["USB-HIDDEN"]
    allHidden.restartAvailable = false
    let hiddenRender = RenderedWindow(
        DroidScoutPopoverView(model: allHidden, openSettings: {}, openInstallProgress: {}),
        size: NSSize(width: 390, height: 520)
    )
    await hiddenRender.settle()
    #expect(hiddenRender.distinctRenderedColorCount() > 8)
    hiddenRender.close()
    #expect(allHidden.visibleDevices.isEmpty)
}

@MainActor
private func verifyStatusBarPresentationReflectsDeviceAndADBState() {
    let warning = StatusItemPresenter.presentation(
        devices: [
            TestSupport.device(serial: "USB1", state: .online, friendlyName: "Pixel 8"),
            TestSupport.device(serial: "USB2", state: .offline, friendlyName: "Offline Pixel")
        ],
        adbStatus: .healthy(path: "/tmp/adb", version: "35.0.2")
    )
    #expect(warning.title == " 1")
    #expect(warning.toolTip == "Droid Scout: 1 online, 1 need attention")
    #expect(warning.tintColor == NSColor.systemOrange)

    let healthy = StatusItemPresenter.presentation(
        devices: [
            TestSupport.device(serial: "USB1", state: .online, friendlyName: "Pixel 8"),
            TestSupport.device(serial: "USB2", state: .online, friendlyName: "Pixel 9")
        ],
        adbStatus: .healthy(path: "/tmp/adb", version: "35.0.2")
    )
    #expect(healthy.title == " 2")
    #expect(healthy.toolTip == "Droid Scout: 2 online")
    #expect(healthy.tintColor == nil)

    let checking = StatusItemPresenter.presentation(devices: [], adbStatus: .checking)
    #expect(checking.title == "")
    #expect(checking.toolTip == "Droid Scout: checking ADB")
    #expect(checking.tintColor == NSColor.systemRed)

    let missing = StatusItemPresenter.presentation(devices: [], adbStatus: .missing(message: "ADB missing"))
    #expect(missing.title == "")
    #expect(missing.toolTip == "Droid Scout: ADB setup required")
    #expect(missing.tintColor == NSColor.systemRed)

    let failed = StatusItemPresenter.presentation(
        devices: [TestSupport.device(serial: "USB1", state: .online, friendlyName: "Pixel 8")],
        adbStatus: .failed(path: nil, message: "ADB failed")
    )
    #expect(failed.title == " 1")
    #expect(failed.toolTip == "Droid Scout: ADB setup required")
    #expect(failed.tintColor == NSColor.systemRed)
}

@MainActor
private final class RenderedWindow {
    private let rootView: NSView
    private let window: NSWindow

    init<Content: View>(_ view: Content, size: NSSize) {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFront(nil)
        rootView = hostingView
        self.window = window
    }

    func settle() async {
        rootView.needsLayout = true
        rootView.layoutSubtreeIfNeeded()
        await settleMacUI()
        rootView.layoutSubtreeIfNeeded()
    }

    func distinctRenderedColorCount(sampleStride: Int = 12) -> Int {
        guard let representation = rootView.bitmapImageRepForCachingDisplay(in: rootView.bounds) else {
            return 0
        }
        rootView.cacheDisplay(in: rootView.bounds, to: representation)

        var colors: Set<String> = []
        let width = max(1, representation.pixelsWide)
        let height = max(1, representation.pixelsHigh)
        for x in stride(from: 0, to: width, by: sampleStride) {
            for y in stride(from: 0, to: height, by: sampleStride) {
                guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let red = Int((color.redComponent * 255).rounded())
                let green = Int((color.greenComponent * 255).rounded())
                let blue = Int((color.blueComponent * 255).rounded())
                let alpha = Int((color.alphaComponent * 255).rounded())
                colors.insert("\(red),\(green),\(blue),\(alpha)")
                if colors.count > 32 {
                    return colors.count
                }
            }
        }
        return colors.count
    }

    func clickButton(titled title: String) -> Bool {
        if let button = buttons().first(where: { button in
            button.title == title || button.attributedTitle.string == title
        }) {
            button.performClick(nil)
            return true
        }
        return accessibilityElements(of: rootView).contains { element in
            guard let accessible = element as? NSAccessibilityProtocol else { return false }
            let names: [String?] = [
                accessible.accessibilityTitle(),
                accessible.accessibilityLabel(),
                accessible.accessibilityValue() as? String
            ]
            guard names.contains(title) else { return false }
            return (element as? NSAccessibilityButton)?.accessibilityPerformPress() ?? false
        }
    }

    func views<ViewType: NSView>(of type: ViewType.Type) -> [ViewType] {
        descendants(of: rootView).compactMap { $0 as? ViewType }
    }

    func close() {
        rootView.removeFromSuperview()
        window.close()
    }

    private func buttons() -> [NSButton] {
        descendants(of: rootView).compactMap { $0 as? NSButton }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    private func accessibilityElements(of element: Any) -> [Any] {
        guard let accessible = element as? NSAccessibilityProtocol,
              let children = accessible.accessibilityChildren()
        else {
            return []
        }
        return children + children.flatMap(accessibilityElements)
    }
}

private func mouseEvent(location: NSPoint) -> NSEvent {
    NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: location,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    )!
}

@MainActor
private func makePopulatedUIModel(root: URL) -> DroidScoutModel {
    let store = LocalStore(
        supportURL: root.appendingPathComponent("Support", isDirectory: true),
        logsURL: root.appendingPathComponent("Logs", isDirectory: true)
    )
    let chosenADB = root.appendingPathComponent("chosen-adb")
    let addedProject = root.appendingPathComponent("AddedProject", isDirectory: true)
    let chosenAPK = root.appendingPathComponent("chosen.apk")
    let model = DroidScoutModel(
        store: store,
        notificationManager: AppNotificationManager(
            requestAuthorizationHandler: {},
            deliverNotification: { _, _ in }
        ),
        logSessionManager: LogSessionManager(
            logsURL: root.appendingPathComponent("Logs", isDirectory: true),
            openLogHandler: { _, _ in },
            revealLogsHandler: { _ in }
        ),
        updateService: UpdateService { _ in },
        chooseADBURLProvider: { chosenADB },
        projectFolderURLsProvider: { [addedProject] },
        installAPKURLsProvider: { [chosenAPK] },
        shellOpener: { _ in },
        diagnosticsRevealer: { _ in },
        appBundleURLProvider: { root.appendingPathComponent("Droid Scout.app", isDirectory: true) },
        restartLauncher: { _ in },
        appTerminator: {}
    )
    model.settings.notificationMode = .off
    model.settings.logTarget = .zed
    model.settings.logRetentionDays = 10
    model.settings.packagePollingInterval = 20
    model.settings.confidenceThreshold = .high
    model.settings.hiddenDeviceIdentities = ["USB-HIDDEN"]
    model.adbStatus = .healthy(path: "/tmp/adb", version: "35.0.2")
    model.restartAvailable = true
    model.isRefreshingDevices = true
    model.devices = [
        TestSupport.device(serial: "USB1", state: .online, friendlyName: "Pixel 8", transportHint: "USB"),
        TestSupport.device(serial: "USB2", state: .unauthorized, friendlyName: "Needs Auth", transportHint: "USB"),
        TestSupport.device(serial: "USB3", state: .offline, friendlyName: "Offline Pixel", transportHint: "Wi-Fi"),
        TestSupport.device(serial: "USB-HIDDEN", state: .online, friendlyName: "Hidden Pixel"),
        TestSupport.device(serial: "avd:Medium_API", state: .stopped, friendlyName: "Medium API", avdName: "Medium_API")
    ]
    model.selectedSerials = ["USB1"]
    model.artifacts = [
        TestSupport.artifact(
            paths: [root.appendingPathComponent("app-debug.apk").pathString],
            packageName: "com.example.debug",
            versionName: "2.0",
            versionCode: "42",
            variant: "debug",
            source: .droidScout
        ),
        TestSupport.artifact(
            paths: [root.appendingPathComponent("bundle.aab").pathString],
            packageName: "com.example.bundle",
            versionName: "3.0",
            versionCode: "7",
            variant: "release",
            kind: .aab,
            source: .indexedProject
        )
    ]
    model.activities = ActivityKind.allCasesForUITests.enumerated().map { index, kind in
        ActivityEvent(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
            kind: kind,
            title: "\(kind.rawValue.capitalized) activity",
            detail: "Rendered by macOS UI integration test",
            deviceSerials: ["USB1"],
            success: index.isMultiple(of: 2)
        )
    }
    model.installResults = [
        installResult(name: "QueuedApp", status: .queued),
        installResult(name: "InstallingApp", status: .installing),
        installResult(name: "SuccessApp", status: .success, stdout: "Success"),
        installResult(name: "FailedApp", status: .failed, stderr: "Failure"),
        installResult(name: "SkippedApp", status: .skipped, stderr: "Device is offline")
    ]
    model.activeLogSessions = [
        LogSessionManager.Session(
            id: UUID(),
            deviceSerial: "USB1",
            fileURL: root.appendingPathComponent("Logs/USB1.log"),
            startedAt: Date()
        )
    ]
    return model
}

private func installResult(name: String, status: InstallStatus, stdout: String = "", stderr: String = "") -> InstallResult {
    InstallResult(
        id: UUID(),
        deviceSerial: "USB1",
        artifactID: UUID(),
        artifactName: name,
        artifactPath: "/tmp/\(name).apk",
        status: status,
        stdout: stdout,
        stderr: stderr,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        completedAt: status.isTerminal ? Date(timeIntervalSince1970: 1_700_000_100) : nil
    )
}

@MainActor
private func settleMacUI() async {
    for _ in 0..<12 {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

private extension ActivityKind {
    static var allCasesForUITests: [ActivityKind] {
        [.device, .install, .deploy, .log, .update, .adb]
    }
}
