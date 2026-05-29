import AppKit
import DroidScout
import UniformTypeIdentifiers
import UserNotifications

@MainActor
enum MacSystemActions {
    static func make() -> DroidScoutSystemActions {
        DroidScoutSystemActions(
            chooseADBURLProvider: chooseADBURL,
            projectFolderURLsProvider: projectFolderURLs,
            installAPKURLsProvider: installAPKURLs,
            textCopier: copyText,
            shellOpener: openShellInTerminal,
            diagnosticsRevealer: revealInFinder,
            appBundleURLProvider: appBundleURLForRestart,
            restartLauncher: launchRestart,
            appTerminator: { NSApplication.shared.terminate(nil) },
            logOpener: openLog,
            logsRevealer: revealInFinder,
            notificationAuthorizationRequester: requestNotificationAuthorization,
            notificationDeliverer: deliverNotification,
            updateOpener: { NSWorkspace.shared.open($0) }
        )
    }

    private static func chooseADBURL() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose ADB"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func projectFolderURLs() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Add Android Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        return panel.runModal() == .OK ? panel.urls : []
    }

    private static func installAPKURLs() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Install APK"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Install"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "apk") ?? .data,
            UTType(filenameExtension: "aab") ?? .data
        ]
        return panel.runModal() == .OK ? panel.urls : []
    }

    private static func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func openShellInTerminal(command: String) {
        let script = "tell application \"Terminal\" to do script \(command.debugDescription)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func showFooterMenu(_ menu: NSMenu, from sourceView: NSView) {
        menu.font = .systemFont(ofSize: 13)
        menu.popUp(positioning: nil, at: NSPoint(x: sourceView.bounds.maxX - 4, y: sourceView.bounds.maxY), in: sourceView)
    }

    static func showDeviceMenu(_ menu: NSMenu, from button: NSButton) {
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: button.bounds.maxY + 2), in: button)
    }

    private static func appBundleURLForRestart() -> URL? {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return nil }
        return bundleURL
    }

    private static func launchRestart(bundleURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.4; /usr/bin/open \(bundleURL.path(percentEncoded: false).shellEscapedForDroidScout)"]
        try? process.run()
    }

    private static func openLog(fileURL: URL, target: LogTarget) {
        switch target {
        case .terminal:
            let command = "tail -f \(fileURL.path(percentEncoded: false).shellEscapedForDroidScout)"
            let script = "tell application \"Terminal\" to do script \(command.debugDescription)"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            try? process.run()
        case .vscode:
            openWithApp("Visual Studio Code", fileURL: fileURL)
        case .zed:
            openWithApp("Zed", fileURL: fileURL)
        case .defaultApp:
            NSWorkspace.shared.open(fileURL)
        }
    }

    private static func openWithApp(_ appName: String, fileURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [fileURL],
            withApplicationAt: URL(fileURLWithPath: "/Applications/\(appName).app"),
            configuration: configuration
        )
    }

    private static func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func deliverNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let bundleID = Bundle.main.bundleIdentifier ?? "com.droidscout.app"
        let request = UNNotificationRequest(identifier: "\(bundleID).\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

private extension String {
    var shellEscapedForDroidScout: String {
        "'\(replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
