import AppKit
import DroidScout
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

@MainActor
enum MacSystemActions {
    static func make() -> DroidScoutSystemActions {
        DroidScoutSystemActions(
            chooseADBURLProvider: chooseADBURL,
            chooseScrcpyURLProvider: chooseScrcpyURL,
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
            updateOpener: { NSWorkspace.shared.open($0) },
            launchAtLoginStatusProvider: launchAtLoginEnabled,
            launchAtLoginSetter: setLaunchAtLoginEnabled,
            saveURLProvider: chooseSaveURL,
            packagePromptProvider: packagePrompt,
            portForwardPromptProvider: portForwardPrompt
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

    private static func chooseScrcpyURL() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose scrcpy"
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

    private static func openCommandInTerminal(title: String, scriptContent: String) {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "droid-scout-\(UUID().uuidString.prefix(8)).command"
        let fileURL = tempDir.appendingPathComponent(fileName)
        
        let fileContents = """
        #!/bin/bash
        # \(title)
        \(scriptContent)
        """
        
        do {
            try fileContents.write(to: fileURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
            
            NSWorkspace.shared.open(fileURL)
            
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            print("Failed to launch terminal session: \(error.localizedDescription)")
        }
    }

    private static func openShellInTerminal(command: String) {
        openCommandInTerminal(
            title: "Droid Scout Shell",
            scriptContent: "exec \(command)"
        )
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
            openCommandInTerminal(
                title: "Droid Scout Log Stream",
                scriptContent: "exec \(command)"
            )
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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { @Sendable _, _ in }
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

    private static func launchAtLoginEnabled() -> Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    private static func setLaunchAtLoginEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }

    private static func chooseSaveURL(defaultName: String, allowedExtension: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save As"
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [allowedExtension == "png" ? UTType.png : UTType.mpeg4Movie]
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func packagePrompt(title: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.placeholderString = "com.example.app"
        alert.accessoryView = textField
        
        return alert.runModal() == .alertFirstButtonReturn ? textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    private static func portForwardPrompt() -> (type: String, local: String, remote: String)? {
        let alert = NSAlert()
        alert.messageText = "Configure Port Forwarding/Reverse"
        alert.informativeText = "Specify the type and the local/remote port specifications."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 100))
        
        let typeLabel = NSTextField(labelWithString: "Type:")
        typeLabel.frame = NSRect(x: 0, y: 72, width: 60, height: 20)
        let typeSelect = NSSegmentedControl(labels: ["Forward", "Reverse"], trackingMode: .selectOne, target: nil, action: nil)
        typeSelect.frame = NSRect(x: 70, y: 70, width: 200, height: 24)
        typeSelect.setSelected(true, forSegment: 0)
        
        let localLabel = NSTextField(labelWithString: "Local:")
        localLabel.frame = NSRect(x: 0, y: 38, width: 60, height: 20)
        let localField = NSTextField(frame: NSRect(x: 70, y: 36, width: 200, height: 22))
        localField.placeholderString = "tcp:8080"
        
        let remoteLabel = NSTextField(labelWithString: "Remote:")
        remoteLabel.frame = NSRect(x: 0, y: 4, width: 60, height: 20)
        let remoteField = NSTextField(frame: NSRect(x: 70, y: 2, width: 200, height: 22))
        remoteField.placeholderString = "tcp:8080"
        
        container.addSubview(typeLabel)
        container.addSubview(typeSelect)
        container.addSubview(localLabel)
        container.addSubview(localField)
        container.addSubview(remoteLabel)
        container.addSubview(remoteField)
        
        alert.accessoryView = container
        
        if alert.runModal() == .alertFirstButtonReturn {
            let type = typeSelect.selectedSegment == 0 ? "forward" : "reverse"
            let local = localField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let remote = remoteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !local.isEmpty && !remote.isEmpty {
                return (type, local, remote)
            }
        }
        return nil
    }
}

private extension String {
    var shellEscapedForDroidScout: String {
        "'\(replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
