import Darwin
import Foundation
@testable import DroidScout

enum TestSupport {
    static func temporaryDirectory(_ name: String = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroidScoutTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    static func touch(_ url: URL, modifiedAt date: Date? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        if let date {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.pathString)
        }
    }

    static func executableScript(_ url: URL, body: String) throws {
        try write("#!/bin/sh\n\(body)\n", to: url)
        guard chmod(url.pathString, 0o755) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func device(
        serial: String,
        state: DeviceConnectionState = .online,
        friendlyName: String = "Pixel 8",
        androidVersion: String? = "15",
        apiLevel: String? = "35",
        transportHint: String? = "USB",
        lastSeen: Date = Date(timeIntervalSince1970: 1_700_000_000),
        avdName: String? = nil
    ) -> AndroidDevice {
        AndroidDevice(
            serial: serial,
            state: state,
            friendlyName: friendlyName,
            androidVersion: androidVersion,
            apiLevel: apiLevel,
            transportHint: transportHint,
            lastSeen: lastSeen,
            avdName: avdName
        )
    }

    static func artifact(
        id: UUID = UUID(),
        paths: [String] = ["/tmp/app.apk"],
        packageName: String? = "com.example.app",
        versionName: String? = "1.0",
        versionCode: String? = "1",
        variant: String? = "debug",
        projectPath: String? = nil,
        kind: ArtifactKind = .apk,
        lastSeen: Date = Date(timeIntervalSince1970: 1_700_000_000),
        source: ArtifactSource = .droidScout,
        confidence: DeployConfidence? = nil,
        devices: [String] = [],
        perDeviceResults: [String: String] = [:],
        evidence: String? = nil
    ) -> ArtifactRecord {
        ArtifactRecord(
            id: id,
            paths: paths,
            packageName: packageName,
            versionName: versionName,
            versionCode: versionCode,
            variant: variant,
            projectPath: projectPath,
            kind: kind,
            lastSeen: lastSeen,
            source: source,
            confidence: confidence,
            devices: devices,
            perDeviceResults: perDeviceResults,
            evidence: evidence
        )
    }
}
