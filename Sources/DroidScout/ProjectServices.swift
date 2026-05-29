import Foundation

final class ArtifactIndexer: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func indexProjects(paths: [String]) async -> [ArtifactRecord] {
        let fileManager = self.fileManager
        return await Task.detached(priority: .utility) {
            var records: [ArtifactRecord] = []
            for root in paths {
                records.append(contentsOf: Self.scanProject(root: root, fileManager: fileManager))
            }
            return records.sorted { $0.lastSeen > $1.lastSeen }
        }.value
    }

    private static func scanProject(root: String, fileManager: FileManager) -> [ArtifactRecord] {
        let rootURL = URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var apkURLsByDirectory: [URL: [URL]] = [:]
        var aabURLs: [URL] = []
        var metadataByDirectory: [URL: OutputMetadata] = [:]

        for case let fileURL as URL in enumerator {
            let path = fileURL.pathString
            if path.contains("/.gradle/") || path.contains("/build/intermediates/") {
                enumerator.skipDescendants()
                continue
            }

            switch fileURL.lastPathComponent {
            case "output-metadata.json":
                if let metadata = readMetadata(fileURL) {
                    metadataByDirectory[fileURL.deletingLastPathComponent()] = metadata
                }
            default:
                if path.contains("/build/outputs/apk/"), fileURL.pathExtension.lowercased() == "apk" {
                    apkURLsByDirectory[fileURL.deletingLastPathComponent(), default: []].append(fileURL)
                } else if path.contains("/build/outputs/bundle/"), fileURL.pathExtension.lowercased() == "aab" {
                    aabURLs.append(fileURL)
                }
            }
        }

        var records: [ArtifactRecord] = []
        for (directory, apks) in apkURLsByDirectory {
            let sortedAPKs = apks.sorted { $0.lastPathComponent < $1.lastPathComponent }
            let metadata = metadataByDirectory[directory]
            let elements = metadata?.elements ?? []

            if sortedAPKs.count > 1, let packageName = metadata?.applicationId {
                records.append(makeRecord(
                    paths: sortedAPKs.map(\.pathString),
                    kind: .splitAPK,
                    source: .indexedProject,
                    metadata: metadata,
                    element: elements.first,
                    fallbackPackage: packageName,
                    variant: variantName(from: directory, rootURL: rootURL),
                    fileManager: fileManager
                ))
            } else {
                for apkURL in sortedAPKs {
                    let element = elements.first { $0.outputFile == apkURL.lastPathComponent } ?? elements.first
                    records.append(makeRecord(
                        paths: [apkURL.pathString],
                        kind: .apk,
                        source: .indexedProject,
                        metadata: metadata,
                        element: element,
                        fallbackPackage: metadata?.applicationId,
                        variant: variantName(from: directory, rootURL: rootURL),
                        fileManager: fileManager
                    ))
                }
            }
        }

        for aabURL in aabURLs {
            records.append(makeRecord(
                paths: [aabURL.pathString],
                kind: .aab,
                source: .indexedProject,
                metadata: nil,
                element: nil,
                fallbackPackage: nil,
                variant: variantName(from: aabURL.deletingLastPathComponent(), rootURL: rootURL),
                fileManager: fileManager
            ))
        }

        return records
    }

    private static func makeRecord(
        paths: [String],
        kind: ArtifactKind,
        source: ArtifactSource,
        metadata: OutputMetadata?,
        element: OutputMetadata.Element?,
        fallbackPackage: String?,
        variant: String?,
        fileManager: FileManager
    ) -> ArtifactRecord {
        let newestDate = paths
            .compactMap { try? fileManager.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
            .max() ?? Date()
        let apkMetadata = kind == .aab ? nil : paths.first.flatMap { APKMetadataReader.read(path: $0) }
        let evidenceSuffix = apkMetadata == nil ? "" : " Metadata parsed from APK."

        return ArtifactRecord(
            id: UUID(),
            paths: paths,
            packageName: metadata?.applicationId ?? fallbackPackage ?? apkMetadata?.packageName,
            versionName: element?.versionName ?? apkMetadata?.versionName,
            versionCode: element?.versionCode.map(String.init) ?? apkMetadata?.versionCode,
            variant: variant,
            kind: kind,
            lastSeen: newestDate,
            source: source,
            confidence: nil,
            devices: [],
            perDeviceResults: [:],
            evidence: "Indexed from Gradle output under \(URL(fileURLWithPath: paths.first ?? "").deletingLastPathComponent().pathString).\(evidenceSuffix)"
        )
    }

    private static func readMetadata(_ url: URL) -> OutputMetadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OutputMetadata.self, from: data)
    }

    private static func variantName(from directory: URL, rootURL: URL) -> String? {
        let relative = directory.pathString.replacingOccurrences(of: rootURL.pathString, with: "")
        let parts = relative.split(separator: "/").map(String.init)
        if let apkIndex = parts.lastIndex(of: "apk"), parts.indices.contains(apkIndex + 1) {
            return parts[(apkIndex + 1)...].joined(separator: "/")
        }
        if let bundleIndex = parts.lastIndex(of: "bundle"), parts.indices.contains(bundleIndex + 1) {
            return parts[(bundleIndex + 1)...].joined(separator: "/")
        }
        return nil
    }
}

private struct OutputMetadata: Codable {
    struct Element: Codable {
        var type: String?
        var filters: [Filter]?
        var attributes: [Attribute]?
        var versionCode: Int?
        var versionName: String?
        var outputFile: String?
    }

    struct Filter: Codable {
        var filterType: String?
        var value: String?
    }

    struct Attribute: Codable {
        var name: String?
        var value: String?
    }

    var version: Int?
    var artifactType: String?
    var applicationId: String?
    var variantName: String?
    var elements: [Element]
}

final class PackageStatePoller: @unchecked Sendable {
    private let adbClient: ADBClient

    init(adbClient: ADBClient) {
        self.adbClient = adbClient
    }

    func snapshots(for packageIDs: Set<String>, devices: [AndroidDevice]) async -> [PackageSnapshot] {
        guard !packageIDs.isEmpty else { return [] }
        var snapshots: [PackageSnapshot] = []
        for device in devices where device.state == .online {
            for packageID in packageIDs {
                if let snapshot = await snapshot(packageID: packageID, deviceSerial: device.serial) {
                    snapshots.append(snapshot)
                }
            }
        }
        return snapshots
    }

    private func snapshot(packageID: String, deviceSerial: String) async -> PackageSnapshot? {
        let result = await adbClient.run(
            serial: deviceSerial,
            arguments: ["shell", "dumpsys", "package", packageID],
            timeout: 10
        )
        guard result.succeeded, result.stdout.contains("Package [\(packageID)]") || result.stdout.contains("Packages:") else {
            return nil
        }

        return PackageDumpsysParser.parse(packageID: packageID, deviceSerial: deviceSerial, stdout: result.stdout)
    }
}

enum PackageDumpsysParser {
    static func parse(packageID: String, deviceSerial: String, stdout: String, observedAt: Date = Date()) -> PackageSnapshot? {
        guard stdout.contains("Package [\(packageID)]") || stdout.contains("Packages:") else {
            return nil
        }

        return PackageSnapshot(
            deviceSerial: deviceSerial,
            packageName: packageID,
            versionName: parseValue(prefix: "versionName=", in: stdout),
            versionCode: parseVersionCode(stdout),
            firstInstallTime: parseValue(prefix: "firstInstallTime=", in: stdout),
            lastUpdateTime: parseValue(prefix: "lastUpdateTime=", in: stdout),
            observedAt: observedAt
        )
    }

    private static func parseValue(prefix: String, in text: String) -> String? {
        text
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(prefix) else { return nil }
                return String(trimmed.dropFirst(prefix.count)).nilIfBlank
            }
            .first
    }

    private static func parseVersionCode(_ text: String) -> String? {
        guard let line = text.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("versionCode=") }) else {
            return nil
        }
        let value = line.trimmingCharacters(in: .whitespaces).dropFirst("versionCode=".count)
        return value.split(separator: " ").first.map(String.init)
    }
}

struct DeployCorrelation {
    var artifact: ArtifactRecord?
    var confidence: DeployConfidence
    var evidence: String
}

final class DeployCorrelator: @unchecked Sendable {
    func correlate(snapshot: PackageSnapshot, artifacts: [ArtifactRecord]) -> DeployCorrelation {
        let candidates = artifacts.filter { $0.packageName == snapshot.packageName && $0.kind != .aab }
        guard !candidates.isEmpty else {
            return DeployCorrelation(
                artifact: nil,
                confidence: .low,
                evidence: "Package changed on device, but no matching local APK artifact was indexed."
            )
        }

        if let exact = candidates.first(where: { artifact in
            let codeMatches = artifact.versionCode == nil || artifact.versionCode == snapshot.versionCode
            let nameMatches = artifact.versionName == nil || artifact.versionName == snapshot.versionName
            return codeMatches && nameMatches
        }) {
            var artifact = exact
            artifact.confidence = .high
            artifact.source = .external
            artifact.evidence = "Matched package \(snapshot.packageName) by version metadata."
            return DeployCorrelation(artifact: artifact, confidence: .high, evidence: artifact.evidence ?? "")
        }

        let newest = candidates.sorted(by: { $0.lastSeen > $1.lastSeen })[0]
        var artifact = newest
        artifact.confidence = .medium
        artifact.source = .external
        artifact.evidence = "Matched package \(snapshot.packageName) by application ID; version metadata did not exactly match."
        return DeployCorrelation(artifact: artifact, confidence: .medium, evidence: artifact.evidence ?? "")
    }
}
