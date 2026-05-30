import Foundation

public struct DroidScoutSystemActions {
    public var chooseADBURLProvider: @MainActor () -> URL?
    public var chooseScrcpyURLProvider: @MainActor () -> URL?
    public var projectFolderURLsProvider: @MainActor () -> [URL]
    public var installAPKURLsProvider: @MainActor () -> [URL]
    public var textCopier: @MainActor (String) -> Void
    public var shellOpener: @MainActor (String) -> Void
    public var diagnosticsRevealer: @MainActor (URL) -> Void
    public var appBundleURLProvider: @MainActor () -> URL?
    public var restartLauncher: @MainActor (URL) -> Void
    public var appTerminator: @MainActor () -> Void
    public var logOpener: @MainActor (URL, LogTarget) -> Void
    public var logsRevealer: @MainActor (URL) -> Void
    public var notificationAuthorizationRequester: @MainActor () -> Void
    public var notificationDeliverer: @MainActor (_ title: String, _ body: String) -> Void
    public var updateOpener: @MainActor (URL) -> Void
    public var saveURLProvider: @MainActor (_ defaultName: String, _ allowedExtension: String) -> URL?
    public var packagePromptProvider: @MainActor (_ title: String, _ message: String) -> String?
    public var portForwardPromptProvider: @MainActor () -> (type: String, local: String, remote: String)?

    public init(
        chooseADBURLProvider: @escaping @MainActor () -> URL? = { nil },
        chooseScrcpyURLProvider: @escaping @MainActor () -> URL? = { nil },
        projectFolderURLsProvider: @escaping @MainActor () -> [URL] = { [] },
        installAPKURLsProvider: @escaping @MainActor () -> [URL] = { [] },
        textCopier: @escaping @MainActor (String) -> Void = { _ in },
        shellOpener: @escaping @MainActor (String) -> Void = { _ in },
        diagnosticsRevealer: @escaping @MainActor (URL) -> Void = { _ in },
        appBundleURLProvider: @escaping @MainActor () -> URL? = { nil },
        restartLauncher: @escaping @MainActor (URL) -> Void = { _ in },
        appTerminator: @escaping @MainActor () -> Void = {},
        logOpener: @escaping @MainActor (URL, LogTarget) -> Void = { _, _ in },
        logsRevealer: @escaping @MainActor (URL) -> Void = { _ in },
        notificationAuthorizationRequester: @escaping @MainActor () -> Void = {},
        notificationDeliverer: @escaping @MainActor (_ title: String, _ body: String) -> Void = { _, _ in },
        updateOpener: @escaping @MainActor (URL) -> Void = { _ in },
        saveURLProvider: @escaping @MainActor (_ defaultName: String, _ allowedExtension: String) -> URL? = { _, _ in nil },
        packagePromptProvider: @escaping @MainActor (_ title: String, _ message: String) -> String? = { _, _ in nil },
        portForwardPromptProvider: @escaping @MainActor () -> (type: String, local: String, remote: String)? = { nil }
    ) {
        self.chooseADBURLProvider = chooseADBURLProvider
        self.chooseScrcpyURLProvider = chooseScrcpyURLProvider
        self.projectFolderURLsProvider = projectFolderURLsProvider
        self.installAPKURLsProvider = installAPKURLsProvider
        self.textCopier = textCopier
        self.shellOpener = shellOpener
        self.diagnosticsRevealer = diagnosticsRevealer
        self.appBundleURLProvider = appBundleURLProvider
        self.restartLauncher = restartLauncher
        self.appTerminator = appTerminator
        self.logOpener = logOpener
        self.logsRevealer = logsRevealer
        self.notificationAuthorizationRequester = notificationAuthorizationRequester
        self.notificationDeliverer = notificationDeliverer
        self.updateOpener = updateOpener
        self.saveURLProvider = saveURLProvider
        self.packagePromptProvider = packagePromptProvider
        self.portForwardPromptProvider = portForwardPromptProvider
    }
}
