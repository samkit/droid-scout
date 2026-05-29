import Foundation

final class LocalStore {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager
    private let supportURL: URL
    private let logsURL: URL

    private var settingsURL: URL { supportURL.appendingPathComponent("settings.json") }
    private var activityURL: URL { supportURL.appendingPathComponent("activity.json") }
    private var artifactsURL: URL { supportURL.appendingPathComponent("artifacts.json") }
    private var deviceNamesURL: URL { supportURL.appendingPathComponent("device-names.json") }

    init(
        fileManager: FileManager = .default,
        supportURL: URL = AppConstants.applicationSupportURL,
        logsURL: URL = AppConstants.logsURL
    ) {
        self.fileManager = fileManager
        self.supportURL = supportURL
        self.logsURL = logsURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        ensureDirectories()
    }

    func ensureDirectories() {
        try? fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: logsURL, withIntermediateDirectories: true)
    }

    func loadSettings() -> AppSettings {
        load(AppSettings.self, from: settingsURL) ?? .defaults
    }

    func saveSettings(_ settings: AppSettings) {
        save(settings, to: settingsURL)
    }

    func loadActivities() -> [ActivityEvent] {
        load([ActivityEvent].self, from: activityURL) ?? []
    }

    func saveActivities(_ activities: [ActivityEvent]) {
        save(Array(activities.prefix(80)), to: activityURL)
    }

    func loadArtifacts() -> [ArtifactRecord] {
        load([ArtifactRecord].self, from: artifactsURL) ?? []
    }

    func saveArtifacts(_ artifacts: [ArtifactRecord]) {
        save(Array(artifacts.prefix(120)), to: artifactsURL)
    }

    func loadDeviceNames() -> [String: String] {
        load([String: String].self, from: deviceNamesURL) ?? [:]
    }

    func saveDeviceNames(_ names: [String: String]) {
        save(names, to: deviceNamesURL)
    }

    func exportDiagnostics(
        settings: AppSettings,
        devices: [AndroidDevice],
        activities: [ActivityEvent],
        artifacts: [ArtifactRecord]
    ) throws -> URL {
        ensureDirectories()
        let redactedDevices = devices.enumerated().map { index, device in
            AndroidDevice(
                serial: "device-\(index + 1)",
                state: device.state,
                friendlyName: device.friendlyName,
                androidVersion: device.androidVersion,
                apiLevel: device.apiLevel,
                transportHint: device.transportHint,
                lastSeen: device.lastSeen,
                avdName: device.avdName
            )
        }

        let payload = DiagnosticsPayload(
            generatedAt: Date(),
            settings: settings,
            devices: redactedDevices,
            activities: activities,
            artifacts: artifacts.map { artifact in
                var redacted = artifact
                redacted.devices = redacted.devices.map { _ in "redacted-device" }
                redacted.perDeviceResults = [:]
                return redacted
            }
        )

        let url = supportURL.appendingPathComponent("diagnostics-\(Int(Date().timeIntervalSince1970)).json")
        let data = try encoder.encode(payload)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            ensureDirectories()
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Droid Scout failed to save \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

private struct DiagnosticsPayload: Codable {
    var generatedAt: Date
    var settings: AppSettings
    var devices: [AndroidDevice]
    var activities: [ActivityEvent]
    var artifacts: [ArtifactRecord]
}
