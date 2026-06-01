import Foundation

public enum AppConstants {
    public static let appName = "Droid Scout"
    static let appDescription = "Native macOS utility for Android developers who keep opening Terminal for the same adb chores."
    static let bundleIdentifier = "com.droidscout.app"
    static let applicationSupportFolder = "Droid Scout"
    static let logsFolder = "Droid Scout"
    static let githubReleasesURL = URL(string: "https://github.com/samkit/droid-scout/releases")!
    static let githubLatestReleaseAPIURL = URL(string: "https://api.github.com/repos/samkit/droid-scout/releases/latest")!
    public static let githubRepoURL = URL(string: "https://github.com/samkit/droid-scout")!
    static let xProfileURL = URL(string: "https://x.com/samkit__")!

    public static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.4"
    }

    static var applicationSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(applicationSupportFolder, isDirectory: true)
    }

    static var logsURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(logsFolder, isDirectory: true)
    }
}

public enum DeviceConnectionState: String, Codable, CaseIterable, Sendable {
    case online
    case unauthorized
    case offline
    case stopped
    case unknown

    init(adbState: String) {
        switch adbState {
        case "device":
            self = .online
        case "unauthorized":
            self = .unauthorized
        case "offline":
            self = .offline
        default:
            self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .online: "online"
        case .unauthorized: "unauthorized"
        case .offline: "offline"
        case .stopped: "stopped"
        case .unknown: "unknown"
        }
    }
}

struct DeviceSnapshot: Codable, Hashable, Sendable {
    var serial: String
    var state: DeviceConnectionState
    var modelHint: String?
    var transportHint: String?
}

public struct AndroidDevice: Identifiable, Codable, Hashable, Sendable {
    public var id: String { serial }
    var serial: String
    var state: DeviceConnectionState
    var friendlyName: String
    var androidVersion: String?
    var apiLevel: String?
    var transportHint: String?
    var lastSeen: Date
    var avdName: String?

    var shortSerial: String {
        if serial.hasPrefix("avd:"), let avdName {
            return avdName
        }
        guard serial.count > 12 else { return serial }
        return "\(serial.prefix(6))...\(serial.suffix(4))"
    }

    var isEmulator: Bool {
        avdName != nil || serial.hasPrefix("emulator-") || serial.hasPrefix("avd:")
    }

    var canStartEmulator: Bool {
        state == .stopped && avdName != nil
    }

    var hiddenIdentity: String {
        if let avdName {
            return "avd:\(avdName)"
        }
        return serial
    }

    var versionSummary: String {
        switch (androidVersion, apiLevel) {
        case let (.some(version), .some(api)):
            "Android \(version) / API \(api)"
        case let (.some(version), .none):
            "Android \(version)"
        case let (.none, .some(api)):
            "API \(api)"
        default:
            "Version unknown"
        }
    }
}

public enum ADBAvailability: Equatable, Sendable {
    case checking
    case healthy(path: String, version: String)
    case missing(message: String)
    case failed(path: String?, message: String)

    public var isHealthy: Bool {
        if case .healthy = self { return true }
        return false
    }

    var path: String? {
        switch self {
        case let .healthy(path, _), let .failed(path?, _):
            path
        case .checking, .missing, .failed(nil, _):
            nil
        }
    }

    var bannerTitle: String? {
        switch self {
        case .checking:
            "Checking ADB..."
        case .healthy:
            nil
        case .missing:
            "ADB was not found"
        case .failed:
            "ADB is not working"
        }
    }

    var bannerMessage: String? {
        switch self {
        case .checking, .healthy:
            nil
        case let .missing(message), let .failed(_, message):
            message
        }
    }
}

enum ArtifactKind: String, Codable, CaseIterable, Sendable {
    case apk
    case splitAPK
    case aab

    var displayName: String {
        switch self {
        case .apk: "APK"
        case .splitAPK: "Split APKs"
        case .aab: "AAB"
        }
    }
}

enum ArtifactSource: String, Codable, CaseIterable, Sendable {
    case droidScout
    case external
    case indexedProject

    var displayName: String {
        switch self {
        case .droidScout: "Droid Scout"
        case .external: "External deploy"
        case .indexedProject: "Project scan"
        }
    }
}

enum DeployConfidence: String, Codable, CaseIterable, Comparable, Sendable {
    case low
    case medium
    case high

    static func < (lhs: DeployConfidence, rhs: DeployConfidence) -> Bool {
        let order: [DeployConfidence] = [.low, .medium, .high]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }

    var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

struct ArtifactRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var paths: [String]
    var packageName: String?
    var versionName: String?
    var versionCode: String?
    var variant: String?
    var kind: ArtifactKind
    var lastSeen: Date
    var source: ArtifactSource
    var confidence: DeployConfidence?
    var devices: [String]
    var perDeviceResults: [String: String]
    var evidence: String?

    var primaryPath: String? { paths.first }

    var isReinstallable: Bool {
        kind != .aab && !paths.isEmpty
    }

    var displayName: String {
        if let packageName, !packageName.isEmpty {
            return packageName
        }
        if let primaryPath {
            return URL(fileURLWithPath: primaryPath).lastPathComponent
        }
        return kind.displayName
    }

    var versionSummary: String {
        var parts: [String] = []
        if let versionName, !versionName.isEmpty { parts.append(versionName) }
        if let versionCode, !versionCode.isEmpty { parts.append("(\(versionCode))") }
        if let variant, !variant.isEmpty { parts.append(variant) }
        return parts.isEmpty ? kind.displayName : parts.joined(separator: " ")
    }

    var reinstallMenuTitle: String {
        var details: [String] = []
        if let variant, !variant.isEmpty {
            details.append(variant)
        }
        details.append(source.displayName)

        return details.isEmpty ? displayName : "\(displayName) - \(details.joined(separator: ", "))"
    }
}

enum ActivityKind: String, Codable, Sendable {
    case device
    case install
    case deploy
    case log
    case update
    case adb
}

struct ActivityEvent: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var timestamp: Date
    var kind: ActivityKind
    var title: String
    var detail: String
    var deviceSerials: [String]
    var success: Bool?
}

public enum InstallStatus: String, Codable, Sendable {
    case queued
    case installing
    case success
    case failed
    case skipped

    public var isTerminal: Bool {
        switch self {
        case .success, .failed, .skipped:
            return true
        case .queued, .installing:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .queued: "Queued"
        case .installing: "Installing"
        case .success: "Success"
        case .failed: "Failed"
        case .skipped: "Skipped"
        }
    }
}

public struct InstallResult: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    var deviceSerial: String
    var artifactID: UUID
    var artifactName: String
    var artifactPath: String?
    public var status: InstallStatus
    var stdout: String
    var stderr: String
    var startedAt: Date
    var completedAt: Date?
}

enum PairingStatus: String, Codable, Sendable {
    case running
    case success
    case failed

    var isTerminal: Bool {
        switch self {
        case .success, .failed:
            return true
        case .running:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .running: "Pairing"
        case .success: "Paired"
        case .failed: "Failed"
        }
    }
}

struct PairingAttempt: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var address: String
    var status: PairingStatus
    var detail: String
    var startedAt: Date
    var completedAt: Date?
}

enum NotificationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case full
    case reduced
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .full: "Full"
        case .reduced: "Reduced"
        case .off: "Off"
        }
    }
}

public enum LogTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case terminal
    case vscode
    case zed
    case defaultApp

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .terminal: "Terminal"
        case .vscode: "VS Code"
        case .zed: "Zed"
        case .defaultApp: "Default App"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    var customADBPath: String?
    var customScrcpyPath: String?
    var watchedProjectPaths: [String]
    var notificationMode: NotificationMode
    var logTarget: LogTarget
    var logRetentionDays: Int
    var packagePollingInterval: Double
    var confidenceThreshold: DeployConfidence
    var backgroundUpdateChecks: Bool
    var launchAtLogin: Bool
    var hiddenDeviceIdentities: [String]

    static let defaults = AppSettings(
        customADBPath: nil,
        customScrcpyPath: nil,
        watchedProjectPaths: [],
        notificationMode: .reduced,
        logTarget: .terminal,
        logRetentionDays: 7,
        packagePollingInterval: 12,
        confidenceThreshold: .medium,
        backgroundUpdateChecks: true,
        launchAtLogin: false,
        hiddenDeviceIdentities: []
    )

    init(
        customADBPath: String?,
        customScrcpyPath: String?,
        watchedProjectPaths: [String],
        notificationMode: NotificationMode,
        logTarget: LogTarget,
        logRetentionDays: Int,
        packagePollingInterval: Double,
        confidenceThreshold: DeployConfidence,
        backgroundUpdateChecks: Bool,
        launchAtLogin: Bool,
        hiddenDeviceIdentities: [String]
    ) {
        self.customADBPath = customADBPath
        self.customScrcpyPath = customScrcpyPath
        self.watchedProjectPaths = watchedProjectPaths
        self.notificationMode = notificationMode
        self.logTarget = logTarget
        self.logRetentionDays = logRetentionDays
        self.packagePollingInterval = packagePollingInterval
        self.confidenceThreshold = confidenceThreshold
        self.backgroundUpdateChecks = backgroundUpdateChecks
        self.launchAtLogin = launchAtLogin
        self.hiddenDeviceIdentities = hiddenDeviceIdentities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        customADBPath = try container.decodeIfPresent(String.self, forKey: .customADBPath)
        customScrcpyPath = try container.decodeIfPresent(String.self, forKey: .customScrcpyPath)
        watchedProjectPaths = try container.decodeIfPresent([String].self, forKey: .watchedProjectPaths) ?? Self.defaults.watchedProjectPaths
        notificationMode = try container.decodeIfPresent(NotificationMode.self, forKey: .notificationMode) ?? Self.defaults.notificationMode
        logTarget = try container.decodeIfPresent(LogTarget.self, forKey: .logTarget) ?? Self.defaults.logTarget
        logRetentionDays = try container.decodeIfPresent(Int.self, forKey: .logRetentionDays) ?? Self.defaults.logRetentionDays
        packagePollingInterval = try container.decodeIfPresent(Double.self, forKey: .packagePollingInterval) ?? Self.defaults.packagePollingInterval
        confidenceThreshold = try container.decodeIfPresent(DeployConfidence.self, forKey: .confidenceThreshold) ?? Self.defaults.confidenceThreshold
        backgroundUpdateChecks = try container.decodeIfPresent(Bool.self, forKey: .backgroundUpdateChecks) ?? Self.defaults.backgroundUpdateChecks
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? Self.defaults.launchAtLogin
        hiddenDeviceIdentities = try container.decodeIfPresent([String].self, forKey: .hiddenDeviceIdentities) ?? Self.defaults.hiddenDeviceIdentities
    }
}

struct PackageSnapshot: Codable, Hashable, Sendable {
    var deviceSerial: String
    var packageName: String
    var versionName: String?
    var versionCode: String?
    var firstInstallTime: String?
    var lastUpdateTime: String?
    var observedAt: Date
}
