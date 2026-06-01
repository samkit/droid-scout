import AppKit
import SwiftUI

public struct DroidScoutPopoverView: View {
    @ObservedObject var model: DroidScoutModel
    @State private var isRecentActivityExpanded = false
    @State private var isHoveringVersion = false
    var openSettings: () -> Void
    var openInstallProgress: () -> Void
    var openPairing: () -> Void
    var footerMenuPresenter: @MainActor (NSMenu, NSView) -> Void
    var deviceMenuPresenter: @MainActor (NSMenu, NSButton) -> Void

    public init(
        model: DroidScoutModel,
        openSettings: @escaping () -> Void,
        openInstallProgress: @escaping () -> Void,
        openPairing: @escaping () -> Void = {},
        footerMenuPresenter: @escaping @MainActor (NSMenu, NSView) -> Void = { _, _ in },
        deviceMenuPresenter: @escaping @MainActor (NSMenu, NSButton) -> Void = { _, _ in }
    ) {
        self.model = model
        self.openSettings = openSettings
        self.openInstallProgress = openInstallProgress
        self.openPairing = openPairing
        self.footerMenuPresenter = footerMenuPresenter
        self.deviceMenuPresenter = deviceMenuPresenter
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let banner = model.statusBanner {
                    StatusBannerView(title: banner.title, message: banner.message, style: banner.style, model: model)
                }
                if model.restartAvailable {
                    RestartBannerView(model: model)
                }
                devicesSection
                actionsSection
                footer
            }
            .padding(.top, 4)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ScrollViewConfigurator())
        .frame(width: 390)
        .background(PopoverMaterial())
    }

    private var header: some View {
        HStack(spacing: 10) {
            headerIcon
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(AppConstants.appName)
                        .font(.headline)
                    
                    Button(action: {
                        NSWorkspace.shared.open(AppConstants.githubRepoURL)
                    }) {
                        Text("v\(AppConstants.appVersion)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isHoveringVersion ? .primary : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(isHoveringVersion ? Color.primary.opacity(0.15) : Color.primary.opacity(0.08))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .onHover { hovering in
                        isHoveringVersion = hovering
                    }
                    .help("Open GitHub Repository")
                }
                
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            RefreshDevicesButton(model: model)

            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Settings")
        }
    }

    @ViewBuilder
    private var headerIcon: some View {
        if let image = Self.makeHeaderIcon() {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: "apps.iphone")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }

    private static func makeHeaderIcon() -> NSImage? {
        let image = NSImage(named: "AndroidStatusIcon")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        image?.accessibilityDescription = AppConstants.appName
        return image
    }

    private var headerSubtitle: String {
        switch model.adbStatus {
        case .checking:
            return "Checking ADB"
        case .healthy:
            let count = model.onlineDevices.count
            return count == 0 ? "No online devices" : "\(count) online device\(count == 1 ? "" : "s")"
        case .missing:
            return "ADB setup required"
        case .failed:
            return "ADB error"
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Devices")
                .font(.subheadline.weight(.semibold))

            if model.visibleDevices.isEmpty {
                if model.hiddenDeviceCount > 0 {
                    EmptyStateRow(icon: "eye.slash", title: "All devices hidden", detail: "Use Show All to bring hidden devices and emulators back.")
                } else {
                    EmptyStateRow(icon: "iphone.slash", title: "No devices found", detail: "Connect a device or create an Android emulator in the SDK.")
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(model.visibleDevices) { device in
                        DeviceRowView(device: device, model: model, menuPresenter: deviceMenuPresenter)
                    }
                }
            }

            if model.hiddenDeviceCount > 0 {
                HiddenDevicesRow(count: model.hiddenDeviceCount, showAll: model.showHiddenDevices)
            }
        }
    }

    private struct ActionPopupItem {
        let title: String
        let action: () -> Void
        let isEnabled: Bool
    }

    private struct ActionPopupButton: NSViewRepresentable {
        let heading: String
        let systemImage: String
        let items: [ActionPopupItem]
        let isEnabled: Bool
        let emptyTitle: String
        let accessibilityIdentifier: String
        let accessibilityLabel: String
        let width: CGFloat
        let height: CGFloat

        func makeNSView(context: Context) -> NSPopUpButton {
            let button = NSPopUpButton(frame: .zero)
            button.target = context.coordinator
            button.action = #selector(Coordinator.itemSelected(_:))
            button.bezelStyle = .rounded
            button.alignment = .center
            if let symbol = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil) {
                symbol.isTemplate = true
                button.image = symbol
                button.imagePosition = .imageLeft
            }
            button.setAccessibilityIdentifier(accessibilityIdentifier)
            button.setAccessibilityLabel(accessibilityLabel)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setFrameSize(NSSize(width: width, height: height))
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: width),
                button.heightAnchor.constraint(equalToConstant: height)
            ])
            return button
        }

        func updateNSView(_ button: NSPopUpButton, context: Context) {
            context.coordinator.parent = self
            if let menu = button.menu {
                menu.removeAllItems()
            } else {
                button.menu = NSMenu()
            }
            button.setAccessibilityIdentifier(accessibilityIdentifier)
            button.setAccessibilityLabel(accessibilityLabel)
            button.setFrameSize(NSSize(width: width, height: height))
            let menu = button.menu!

            let placeholder = NSMenuItem(title: heading, action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)

            if isEnabled && !items.isEmpty {
                for (index, item) in items.enumerated() {
                    let menuItem = NSMenuItem(
                        title: item.title,
                        action: nil,
                        keyEquivalent: ""
                    )
                    menuItem.isEnabled = item.isEnabled
                    menuItem.tag = index
                    button.menu?.addItem(menuItem)
                }
                button.selectItem(at: 0)
            } else {
                let emptyItem = NSMenuItem(title: emptyTitle, action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                button.menu?.addItem(emptyItem)
            }
            resetSelection(button)
        }

        private func resetSelection(_ button: NSPopUpButton) {
            if button.numberOfItems >= 1 {
                button.selectItem(at: 0)
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        final class Coordinator: NSObject {
            var parent: ActionPopupButton
            init(_ parent: ActionPopupButton) {
                self.parent = parent
            }

            @MainActor
            @objc func itemSelected(_ sender: NSPopUpButton) {
                let selectedIndex = sender.indexOfSelectedItem - 1
                guard selectedIndex >= 0, selectedIndex < parent.items.count else {
                    sender.selectItem(at: 0)
                    return
                }
                guard parent.items[selectedIndex].isEnabled else { return }
                parent.items[selectedIndex].action()
                sender.selectItem(at: 0)
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Actions")
                .font(.subheadline.weight(.semibold))

            let actionSpacing: CGFloat = 8
            let buttonHeight: CGFloat = 30
            let buttonWidth: CGFloat = (390 - 28 - actionSpacing) / 2

            HStack(spacing: actionSpacing) {
                Button(action: model.installAPKFromMainAction) {
                    Label("Install APK...", systemImage: "square.and.arrow.down")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .frame(width: buttonWidth, height: buttonHeight)
                .disabled(!model.adbStatus.isHealthy)
                .accessibilityIdentifier("actions.installApk")
                .accessibilityLabel("actions.installApk")

                ActionPopupButton(
                    heading: "Reinstall Recent...",
                    systemImage: "clock.arrow.circlepath",
                    items: model.recentArtifacts.prefix(8).map { artifact in
                        ActionPopupItem(
                            title: artifact.reinstallMenuTitle,
                            action: { model.reinstallRecent(artifact) },
                            isEnabled: true
                        )
                    },
                    isEnabled: model.adbStatus.isHealthy && !model.recentArtifacts.isEmpty,
                    emptyTitle: "No APKs to reinstall",
                    accessibilityIdentifier: "actions.reinstallRecent",
                    accessibilityLabel: "actions.reinstallRecent",
                    width: buttonWidth,
                    height: buttonHeight
                )
            }

            HStack(spacing: actionSpacing) {
                ActionPopupButton(
                    heading: "Start Logs",
                    systemImage: "terminal",
                    items: availableLogTargets.map { target in
                        ActionPopupItem(
                            title: target.displayName,
                            action: { model.startLogsForSelected(target: target) },
                            isEnabled: true
                        )
                    },
                    isEnabled: !model.selectedOnlineDevices.isEmpty,
                    emptyTitle: "No Log targets",
                    accessibilityIdentifier: "actions.startLogs",
                    accessibilityLabel: "actions.startLogs",
                    width: buttonWidth,
                    height: buttonHeight
                )

                Button(action: model.clearLogcatForSelected) {
                    Label("Clear Logcat", systemImage: "trash")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .frame(width: buttonWidth, height: buttonHeight)
                .disabled(model.selectedOnlineDevices.isEmpty)
                .accessibilityIdentifier("actions.clearLogcat")
                .accessibilityLabel("actions.clearLogcat")
            }

            if !model.installResults.isEmpty {
                Button(action: openInstallProgress) {
                    Label("Install Progress", systemImage: "list.bullet.clipboard")
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @MainActor
    private var availableLogTargets: [LogTarget] {
        LogTarget.availableOnCurrentMac
    }

    private var footer: some View {
        VStack(spacing: 0) {
            FooterMenuListView(
                model: model,
                section: .top,
                isRecentActivityExpanded: $isRecentActivityExpanded,
                showPairing: openPairing,
                menuPresenter: footerMenuPresenter
            )
                .frame(height: CGFloat((model.restartAvailable ? 3 : 2) * 28))

            RecentActivityInlineView(model: model)
                .frame(height: isRecentActivityExpanded ? RecentActivityInlineView.height(model: model) : 0, alignment: .top)
                .clipped()

            FooterMenuListView(
                model: model,
                section: .bottom,
                isRecentActivityExpanded: $isRecentActivityExpanded,
                showPairing: openPairing,
                menuPresenter: footerMenuPresenter
            )
                .frame(height: CGFloat(2 * 28))
        }
        .animation(.easeInOut(duration: 0.18), value: isRecentActivityExpanded)
        .overlay(alignment: .top) {
            Divider().opacity(0.45)
        }
    }
}

enum FooterMenuSection {
    case top
    case bottom
}

struct FooterMenuListView: NSViewRepresentable {
    @ObservedObject var model: DroidScoutModel
    var section: FooterMenuSection
    @Binding var isRecentActivityExpanded: Bool
    var showPairing: () -> Void = {}
    var menuPresenter: @MainActor (NSMenu, NSView) -> Void = { _, _ in }

    func makeNSView(context: Context) -> NSStackView {
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.distribution = .fill
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        configure(stackView)
        return stackView
    }

    func updateNSView(_ stackView: NSStackView, context: Context) {
        configure(stackView)
    }

    private func configure(_ stackView: NSStackView) {
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        switch section {
        case .top:
            if model.restartAvailable {
                stackView.addArrangedSubview(row(title: "Restart", action: model.restartToApplyUpdate))
            }

            stackView.addArrangedSubview(row(title: "Advanced", showsSubmenuIndicator: true) { sourceView in
                let menu = NSMenu(title: "Advanced")
                menu.addItem(ClosureMenuItem(
                    title: "Pair Android Device...",
                    enabled: model.adbStatus.isHealthy && !model.isPairingDevice,
                    handler: showPairing
                ))
                menu.addItem(NSMenuItem.separator())
                menu.addItem(ClosureMenuItem(
                    title: "Restart ADB Server",
                    enabled: model.adbStatus.isHealthy && !model.isRestartingADBServer,
                    handler: model.restartADBServer
                ))
                menuPresenter(menu, sourceView)
            })

            stackView.addArrangedSubview(row(title: "Recent Activity", showsSubmenuIndicator: true, isExpanded: isRecentActivityExpanded) { _ in
                withAnimation(.easeInOut(duration: 0.18)) {
                    isRecentActivityExpanded.toggle()
                }
            })

        case .bottom:
            stackView.addArrangedSubview(row(title: "Reveal Logs", action: model.revealLogs))
            stackView.addArrangedSubview(row(title: "Quit", action: model.quit))
        }
    }

    private func row(title: String, action: @escaping () -> Void) -> CodexStyleMenuRowView {
        row(title: title, showsSubmenuIndicator: false) { _ in action() }
    }

    private func row(
        title: String,
        showsSubmenuIndicator: Bool,
        isExpanded: Bool = false,
        action: @escaping (NSView) -> Void
    ) -> CodexStyleMenuRowView {
        let row = CodexStyleMenuRowView(title: title, showsSubmenuIndicator: showsSubmenuIndicator, isExpanded: isExpanded, action: action)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 28),
            row.widthAnchor.constraint(equalToConstant: 362)
        ])
        return row
    }

}

struct RecentActivityInlineView: View {
    @ObservedObject var model: DroidScoutModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.activities.isEmpty {
                EmptyStateRow(icon: "clock", title: "No activity yet", detail: "Installs, deploys, and device changes will appear here.")
            } else {
                VStack(spacing: 6) {
                    ForEach(model.activities.prefix(5)) { activity in
                        ActivityRowView(activity: activity)
                            .frame(height: 42)
                    }
                }
            }

            if !model.activeLogSessions.isEmpty {
                Divider()
                ForEach(model.activeLogSessions) { session in
                    HStack {
                        Image(systemName: "terminal")
                            .foregroundStyle(.secondary)
                        Text(session.fileURL.lastPathComponent)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            model.stopLogSession(session)
                        } label: {
                            Image(systemName: "stop.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop log stream")
                    }
                    .font(.caption)
                    .frame(height: 24)
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
    }

    static func height(model: DroidScoutModel) -> CGFloat {
        if model.activities.isEmpty && model.activeLogSessions.isEmpty {
            return 62
        }
        let activityHeight = CGFloat(min(model.activities.count, 5) * 48)
        let sessionHeight = model.activeLogSessions.isEmpty ? 0 : CGFloat(8 + model.activeLogSessions.count * 28)
        return max(44, activityHeight + sessionHeight + 12)
    }
}

final class CodexStyleMenuRowView: NSControl {
    private let titleField = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private let actionHandler: (NSView) -> Void
    private var trackingAreaRef: NSTrackingArea?
    private var isExpanded: Bool
    private var isRowHighlighted = false {
        didSet {
            needsDisplay = true
            titleField.textColor = isRowHighlighted ? .white : .labelColor
            chevronView.contentTintColor = isRowHighlighted ? .white : .tertiaryLabelColor
        }
    }

    init(title: String, showsSubmenuIndicator: Bool, isExpanded: Bool = false, action: @escaping (NSView) -> Void) {
        actionHandler = action
        self.isExpanded = isExpanded
        super.init(frame: .zero)

        wantsLayer = true
        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: 13)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)

        chevronView.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevronView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevronView.contentTintColor = .tertiaryLabelColor
        chevronView.isHidden = !showsSubmenuIndicator
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevronView)
        updateChevronRotation()

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -8),

            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 10),
            chevronView.heightAnchor.constraint(equalToConstant: 10)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isRowHighlighted = true
    }

    override func mouseExited(with event: NSEvent) {
        isRowHighlighted = false
    }

    override func mouseDown(with event: NSEvent) {
        isRowHighlighted = true
        actionHandler(self)
    }

    override func mouseUp(with event: NSEvent) {
        if !bounds.contains(convert(event.locationInWindow, from: nil)) {
            isRowHighlighted = false
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isRowHighlighted else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 4, yRadius: 4).fill()
    }

    private func updateChevronRotation() {
        chevronView.frameCenterRotation = isExpanded ? 90 : 0
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(performHandler), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc func performHandler() {
        handler()
    }
}

private struct RefreshDevicesButton: View {
    @ObservedObject var model: DroidScoutModel
    @State private var rotation = 0.0

    var body: some View {
        Button(action: model.refreshDevices) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 14, weight: .medium))
                .rotationEffect(.degrees(rotation))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(model.isRefreshingDevices ? "Refreshing..." : "Refresh")
        .accessibilityLabel(model.isRefreshingDevices ? "Refreshing devices" : "Refresh")
        .onAppear {
            if model.isRefreshingDevices {
                startAnimating()
            }
        }
        .onChange(of: model.isRefreshingDevices) { isRefreshing in
            if isRefreshing {
                startAnimating()
            } else {
                stopAnimating()
            }
        }
    }

    private func startAnimating() {
        rotation = 0
        withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
            rotation = 360
        }
    }

    private func stopAnimating() {
        withAnimation(.easeOut(duration: 0.15)) {
            rotation = 0
        }
    }
}

public struct DroidScoutPairingView: View {
    @ObservedObject var model: DroidScoutModel
    @State private var address = ""
    @State private var pairingCode = ""
    @FocusState private var focusedField: Field?

    public init(model: DroidScoutModel) {
        self.model = model
    }

    private enum Field {
        case address
        case pairingCode
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "wifi")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Pair Android Device")
                    .font(.headline)
                Spacer()
                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pairing address")
                        .font(.caption.weight(.semibold))
                    TextField("192.168.1.10:37123", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .address)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Pairing code")
                        .font(.caption.weight(.semibold))
                    SecureField("123456", text: $pairingCode)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .pairingCode)
                }
            }

            pairingProgress

            HStack(spacing: 10) {
                Button("Pair Another") {
                    model.clearPairingAttempt()
                    address = ""
                    pairingCode = ""
                    focusedField = .address
                }
                .disabled(model.isPairingDevice)
                Spacer()
                Button(model.isPairingDevice ? "Pairing..." : "Pair") {
                    model.pairAndroidDevice(address: address, pairingCode: pairingCode)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isPairingDevice || !canSubmit)
            }
        }
        .padding(20)
        .frame(width: 500, height: 300)
        .onAppear {
            focusedField = .address
        }
    }

    @ViewBuilder
    private var pairingProgress: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let attempt = model.pairingAttempt {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: icon(for: attempt.status))
                        .foregroundStyle(color(for: attempt.status))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attempt.address.isEmpty ? "Pairing request" : attempt.address)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(attempt.completedAt ?? attempt.startedAt, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(attempt.status.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color(for: attempt.status))
                }

                if !attempt.status.isTerminal {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(attempt.detail)
                    .font(.caption)
                    .foregroundStyle(attempt.status == .failed ? .red : .secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ready to pair")
                        .font(.subheadline.weight(.semibold))
                    Text("Enter the address and code shown by Android wireless debugging.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusText: String {
        model.pairingAttempt?.status.displayName ?? "Idle"
    }

    private var statusColor: Color {
        guard let status = model.pairingAttempt?.status else { return .secondary }
        return color(for: status)
    }

    private func icon(for status: PairingStatus) -> String {
        switch status {
        case .running: "arrow.triangle.2.circlepath"
        case .success: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func color(for status: PairingStatus) -> Color {
        switch status {
        case .running: .accentColor
        case .success: .green
        case .failed: .red
        }
    }

    private var canSubmit: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct PopoverMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = PassthroughVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
    }
}

struct ScrollViewConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView(frame: .zero)
        DispatchQueue.main.async {
            configureEnclosingScrollView(from: view)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            configureEnclosingScrollView(from: view)
        }
    }

    func configureEnclosingScrollView(from view: NSView) {
        var current: NSView? = view
        while let candidate = current {
            if let scrollView = candidate as? NSScrollView {
                configure(scrollView)
                return
            }
            current = candidate.superview
        }
    }

    func configure(_ scrollView: NSScrollView) {
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .default
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller?.alphaValue = 0.45
        scrollView.horizontalScroller?.alphaValue = 0.45
    }
}

private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class PassthroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct RestartBannerView: View {
    @ObservedObject var model: DroidScoutModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Update installed")
                    .font(.subheadline.weight(.semibold))
                Text("Restart Droid Scout to use the new version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restart", action: model.restartToApplyUpdate)
        }
        .padding(10)
        .background(Color.blue.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct StatusBannerView: View {
    var title: String
    var message: String
    var style: BannerStyle
    @ObservedObject var model: DroidScoutModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: style == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(style == .error ? .red : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                if style == .error {
                    Button("Choose ADB...", action: model.chooseADB)
                    Button("Retry", action: model.retryADBDetection)
                    Button(action: model.copyHomebrewInstallHint) {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy Homebrew install hint")
                } else {
                    Button("Refresh", action: model.refreshDevices)
                }
            }
            .font(.caption)
        }
        .padding(10)
        .background(style == .error ? Color.red.opacity(0.10) : Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct DeviceRowView: View {
    var device: AndroidDevice
    @ObservedObject var model: DroidScoutModel
    var menuPresenter: @MainActor (NSMenu, NSButton) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Toggle("", isOn: selectionBinding)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(device.state != .online)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(device.friendlyName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(device.shortSerial)
                    Text(device.versionSummary)
                    if let transport = device.transportHint {
                        Text(transport)
                    }
                    if model.isLaunchingEmulator(device: device) {
                        Text("Starting...")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            StateBadge(state: device.state)
                .frame(width: 86, alignment: .trailing)

            if device.canStartEmulator {
                Button {
                    model.startEmulator(device: device)
                } label: {
                    if model.isLaunchingEmulator(device: device) {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .focusable(false)
                .disabled(model.isLaunchingEmulator(device: device))
                .help(model.isLaunchingEmulator(device: device) ? "Starting emulator..." : "Start emulator")
            } else {
                Color.clear
                    .frame(width: 30, height: 30)
            }

            DeviceActionsMenuButton(device: device, model: model, menuPresenter: menuPresenter)
            .frame(width: 30, height: 30)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.45)
        }
    }

    private var selectionBinding: Binding<Bool> {
        Binding {
            model.selectedSerials.contains(device.serial)
        } set: { isSelected in
            if isSelected {
                model.selectedSerials.insert(device.serial)
            } else {
                model.selectedSerials.remove(device.serial)
            }
        }
    }
}

struct DeviceActionsMenuButton: NSViewRepresentable {
    var device: AndroidDevice
    @ObservedObject var model: DroidScoutModel
    var menuPresenter: @MainActor (NSMenu, NSButton) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(device: device, model: model, menuPresenter: menuPresenter)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.alignment = .center
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.toolTip = "Device actions"
        button.setAccessibilityLabel("Device actions")
        updateButtonAppearance(button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.device = device
        context.coordinator.model = model
        context.coordinator.menuPresenter = menuPresenter
        updateButtonAppearance(button)
    }

    private func updateButtonAppearance(_ button: NSButton) {
        button.title = ""
        button.image = Self.moreHorizontalImage(color: NSColor.labelColor.withAlphaComponent(0.82))
        button.imageScaling = .scaleNone
    }

    private static func moreHorizontalImage(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18))
        image.lockFocus()
        color.setFill()
        for x in [6.0, 11.0, 16.0] {
            NSBezierPath(ovalIn: NSRect(x: x - 2, y: 7, width: 4, height: 4)).fill()
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    @MainActor
    final class Coordinator: NSObject {
        var device: AndroidDevice
        var model: DroidScoutModel
        var menuPresenter: @MainActor (NSMenu, NSButton) -> Void

        init(device: AndroidDevice, model: DroidScoutModel, menuPresenter: @escaping @MainActor (NSMenu, NSButton) -> Void = { _, _ in }) {
            self.device = device
            self.model = model
            self.menuPresenter = menuPresenter
        }

        @objc func showMenu(_ sender: NSButton) {
            menuPresenter(makeMenu(), sender)
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(menuItem("Copy Serial", action: #selector(copySerial)))
            if device.canStartEmulator {
                let isLaunching = model.isLaunchingEmulator(device: device)
                menu.addItem(menuItem(isLaunching ? "Starting Emulator..." : "Start Emulator", action: #selector(startEmulator), enabled: !isLaunching))
            }
            menu.addItem(menuItem("Install APK...", action: #selector(installAPK), enabled: device.state == .online))
            menu.addItem(NSMenuItem.separator())
            
            menu.addItem(menuItem("Take Screenshot", action: #selector(takeScreenshot), enabled: device.state == .online))
            
            let isRecording = model.activeScreenRecordings[device.serial] != nil
            let recordTitle = isRecording ? "Stop Screen Recording" : "Start Screen Recording"
            menu.addItem(menuItem(recordTitle, action: #selector(toggleScreenRecording), enabled: device.state == .online))
            
            menu.addItem(menuItem("Screen Mirroring (scrcpy)", action: #selector(startMirroring), enabled: device.state == .online))
            menu.addItem(NSMenuItem.separator())
            
            let logStreamItem = NSMenuItem(title: "Open Log Stream", action: nil, keyEquivalent: "")
            logStreamItem.isEnabled = device.state == .online
            let logStreamMenu = NSMenu(title: "Open Log Stream")
            for target in LogTarget.availableOnCurrentMac {
                logStreamMenu.addItem(menuItem(target.displayName, action: selector(for: target)))
            }
            logStreamItem.submenu = logStreamMenu
            menu.addItem(logStreamItem)
            menu.addItem(menuItem("Clear Logcat Buffer", action: #selector(clearLogcatBuffer), enabled: device.state == .online))
            menu.addItem(menuItem("Open Shell", action: #selector(openShell), enabled: device.state == .online))
            menu.addItem(NSMenuItem.separator())
            
            menu.addItem(menuItem("Port Forwarding...", action: #selector(configurePortForwarding), enabled: device.state == .online))
            
            let appControlItem = NSMenuItem(title: "App Control", action: nil, keyEquivalent: "")
            appControlItem.isEnabled = device.state == .online
            let appControlMenu = NSMenu(title: "App Control")
            appControlMenu.addItem(menuItem("Clear App Data...", action: #selector(clearAppData)))
            appControlMenu.addItem(menuItem("Uninstall App...", action: #selector(uninstallApp)))
            appControlItem.submenu = appControlMenu
            menu.addItem(appControlItem)
            
            let rebootItem = NSMenuItem(title: "Reboot Device", action: nil, keyEquivalent: "")
            rebootItem.isEnabled = device.state == .online
            let rebootMenu = NSMenu(title: "Reboot Device")
            rebootMenu.addItem(menuItem("System", action: #selector(rebootSystem)))
            rebootMenu.addItem(menuItem("Bootloader", action: #selector(rebootBootloader)))
            rebootMenu.addItem(menuItem("Recovery", action: #selector(rebootRecovery)))
            if device.isEmulator {
                rebootMenu.addItem(NSMenuItem.separator())
                rebootMenu.addItem(menuItem("Shutdown Emulator", action: #selector(shutdownEmulator)))
            }
            rebootItem.submenu = rebootMenu
            menu.addItem(rebootItem)
            
            menu.addItem(NSMenuItem.separator())
            menu.addItem(menuItem("Remove from List", action: #selector(hideFromList)))
            return menu
        }

        @objc func copySerial() {
            model.copySerial(device)
        }

        @objc func startEmulator() {
            model.startEmulator(device: device)
        }

        @objc func installAPK() {
            model.installAPKFromPanel(preselectedSerial: device.serial)
        }

        @objc func openLogStream() {
            model.selectedSerials = [device.serial]
            model.startLogsForSelected()
        }

        @objc func openLogStreamTerminal() {
            model.selectedSerials = [device.serial]
            model.startLogsForSelected(target: .terminal)
        }

        @objc func openLogStreamVSCode() {
            model.selectedSerials = [device.serial]
            model.startLogsForSelected(target: .vscode)
        }

        @objc func openLogStreamZed() {
            model.selectedSerials = [device.serial]
            model.startLogsForSelected(target: .zed)
        }

        @objc func openLogStreamDefault() {
            model.selectedSerials = [device.serial]
            model.startLogsForSelected(target: .defaultApp)
        }

        @objc func clearLogcatBuffer() {
            model.selectedSerials = [device.serial]
            model.clearLogcatForSelected()
        }

        @objc func openShell() {
            model.openShell(device: device)
        }

        @objc func hideFromList() {
            model.hideDevice(device)
        }

        @objc func takeScreenshot() {
            model.takeScreenshot(device: device)
        }

        @objc func toggleScreenRecording() {
            if model.activeScreenRecordings[device.serial] != nil {
                model.stopScreenRecording(device: device)
            } else {
                model.startScreenRecording(device: device)
            }
        }

        @objc func startMirroring() {
            model.startMirroring(device: device)
        }

        @objc func clearAppData() {
            model.promptAndClearAppData(device: device)
        }

        @objc func uninstallApp() {
            model.promptAndUninstallApp(device: device)
        }

        @objc func configurePortForwarding() {
            model.configurePortForwarding(device: device)
        }

        @objc func rebootSystem() {
            model.rebootDevice(device: device, mode: nil)
        }

        @objc func rebootBootloader() {
            model.rebootDevice(device: device, mode: "bootloader")
        }

        @objc func rebootRecovery() {
            model.rebootDevice(device: device, mode: "recovery")
        }

        @objc func shutdownEmulator() {
            model.shutdownEmulator(device: device)
        }

        func menuItem(_ title: String, action: Selector, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            return item
        }

        func selector(for target: LogTarget) -> Selector {
            switch target {
            case .terminal:
                #selector(openLogStreamTerminal)
            case .vscode:
                #selector(openLogStreamVSCode)
            case .zed:
                #selector(openLogStreamZed)
            case .defaultApp:
                #selector(openLogStreamDefault)
            }
        }
    }
}

private extension LogTarget {
    @MainActor
    static var availableOnCurrentMac: [LogTarget] {
        allCases.filter(\.isAvailableOnCurrentMac)
    }

    @MainActor
    var isAvailableOnCurrentMac: Bool {
        switch self {
        case .terminal:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") != nil
        case .vscode:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") != nil
        case .zed:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.zed.Zed") != nil
        case .defaultApp:
            return true
        }
    }
}

private struct StateBadge: View {
    var state: DeviceConnectionState

    var body: some View {
        Text(state.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(Capsule())
    }

    private var background: Color {
        switch state {
        case .online: Color.green.opacity(0.16)
        case .unauthorized: Color.orange.opacity(0.18)
        case .offline, .stopped, .unknown: Color.gray.opacity(0.18)
        }
    }

    private var foreground: Color {
        switch state {
        case .online: .green
        case .unauthorized: .orange
        case .offline, .stopped, .unknown: .secondary
        }
    }
}

private struct HiddenDevicesRow: View {
    var count: Int
    var showAll: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Show All", action: showAll)
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var message: String {
        "\(count) device\(count == 1 ? " is" : "s are") hidden"
    }
}

private struct ActivityRowView: View {
    var activity: ActivityEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(activity.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(activity.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(activity.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var icon: String {
        switch activity.kind {
        case .device: "iphone"
        case .install: "square.and.arrow.down"
        case .deploy: "arrow.triangle.2.circlepath"
        case .log: "terminal"
        case .update: "sparkles"
        case .adb: "wrench.and.screwdriver"
        }
    }

    private var color: Color {
        if activity.success == false { return .red }
        if activity.success == true { return .green }
        return .secondary
    }
}

private struct EmptyStateRow: View {
    var icon: String
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.45)
        }
    }
}
