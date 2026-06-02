import AppKit
import Combine
import DroidScout
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let popoverWidth: CGFloat = 390
    private let model: DroidScoutModel
    private let statusIcon: NSImage?
    private lazy var popoverHostingController: NSHostingController<DroidScoutPopoverView> = {
        NSHostingController(rootView: DroidScoutPopoverView(
            model: model,
            openSettings: { [weak self] in
                self?.showSettings()
            },
            openInstallProgress: { [weak self] in
                self?.showInstallProgress()
            },
            openPairing: { [weak self] in
                self?.showPairing()
            },
            footerMenuPresenter: MacSystemActions.showFooterMenu,
            deviceMenuPresenter: MacSystemActions.showDeviceMenu,
            onContentHeightChange: { [weak self] height in
                self?.handleContentHeightChange(height)
            }
        ))
    }()
    private var settingsWindow: NSWindow?
    private var installProgressWindow: NSWindow?
    private var pairingWindow: NSWindow?
    private var popoverHeight: CGFloat = 0
    private var reportedPopoverContentHeight: CGFloat = 0
    private var announcedActiveInstallIDs: Set<UUID> = []
    private var cancellables: Set<AnyCancellable> = []
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        model = DroidScoutModel(systemActions: MacSystemActions.make())
        statusIcon = Self.makeStatusIcon()
        super.init()

        configureStatusItem()
        configurePopover()
        bindModel()
        model.start()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.imagePosition = .imageLeft
        button.image = statusIcon
        button.toolTip = AppConstants.appName
        
        ScreenRecordHUDController.statusItemFrameProvider = { [weak self] in
            guard let self = self,
                  let btn = self.statusItem.button,
                  let win = btn.window else { return nil }
            return win.frame
        }
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = popoverHostingController
        popover.contentSize = NSSize(width: popoverWidth, height: 0)
    }

    private func bindModel() {
        model.$devices
            .combineLatest(model.$adbStatus, model.$settings)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self else { return }
                let (_, adbStatus, _) = value
                self.updateStatusItem(devices: self.model.visibleDevices, adbStatus: adbStatus)
            }
            .store(in: &cancellables)

        model.$installResults
            .receive(on: RunLoop.main)
            .sink { [weak self] results in
                self?.handleInstallResultsChanged(results)
            }
            .store(in: &cancellables)

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.resizePopoverToFitContent()
                }
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem(devices: [AndroidDevice], adbStatus: ADBAvailability) {
        guard let button = statusItem.button else { return }
        let presentation = StatusItemPresenter.presentation(devices: devices, adbStatus: adbStatus)
        button.image = statusIcon
        button.contentTintColor = presentation.tintColor
        button.title = presentation.title
        button.toolTip = presentation.toolTip
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            resizePopoverToFitContent()
            installOutsideClickMonitors()
        }
    }

    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if self.isEventInsidePopover(event) {
                return event
            }
            self.popover.performClose(event)
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    private func removeOutsideClickMonitors() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func resizePopoverToFitContent() {
        guard popover.isShown else { return }
        guard let contentView = popover.contentViewController?.view else { return }
        contentView.layoutSubtreeIfNeeded()

        let fittingHeight = reportedPopoverContentHeight
        guard fittingHeight > 0 else {
            DispatchQueue.main.async { [weak self] in
                self?.resizePopoverToFitContent()
            }
            return
        }
        guard fittingHeight.isFinite else { return }

        let maxHeight = maximumPopoverHeight()
        let desiredHeight = min(fittingHeight, maxHeight)

        if popoverHeight != desiredHeight {
            popoverHeight = desiredHeight
            popover.contentSize = NSSize(width: popoverWidth, height: desiredHeight)
        }
    }

    private func handleContentHeightChange(_ measuredHeight: CGFloat) {
        let roundedHeight = measuredHeight.rounded(.up)
        if roundedHeight == reportedPopoverContentHeight { return }
        reportedPopoverContentHeight = roundedHeight
        resizePopoverToFitContent()
    }

    private func maximumPopoverHeight() -> CGFloat {
        let activeScreen = statusItem.button?.window?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen = activeScreen else { return 560 }
        return max(screen.visibleFrame.height * 0.5, 0)
    }

    private func isEventInsidePopover(_ event: NSEvent) -> Bool {
        guard let window = popover.contentViewController?.view.window else { return false }
        if event.window === window {
            return true
        }
        return window.frame.contains(NSEvent.mouseLocation)
    }

    func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = ClosableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(AppConstants.appName) Settings"
        window.contentView = NSHostingView(rootView: DroidScoutSettingsView(model: model))
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showInstallProgress() {
        if let installProgressWindow {
            installProgressWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = ClosableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(AppConstants.appName) Install Progress"
        window.contentView = NSHostingView(rootView: DroidScoutInstallProgressView(model: model))
        window.center()
        window.isReleasedWhenClosed = false
        installProgressWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showPairing() {
        if let pairingWindow {
            pairingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = ClosableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(AppConstants.appName) Pair Android Device"
        window.contentView = NSHostingView(rootView: DroidScoutPairingView(model: model))
        window.center()
        window.isReleasedWhenClosed = false
        pairingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleInstallResultsChanged(_ results: [InstallResult]) {
        let activeIDs = Set(results.filter { !$0.status.isTerminal }.map(\.id))
        let newActiveIDs = activeIDs.subtracting(announcedActiveInstallIDs)
        if !newActiveIDs.isEmpty {
            showInstallProgress()
        }
        announcedActiveInstallIDs = activeIDs
    }

    private static func makeStatusIcon() -> NSImage? {
        let image = NSImage(named: "AndroidStatusIcon")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        image?.accessibilityDescription = AppConstants.appName
        return image
    }
}

extension StatusBarController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitors()
    }

    func popoverDidShow(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.resizePopoverToFitContent()
        }
    }
}

final class ClosableWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            self.performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
