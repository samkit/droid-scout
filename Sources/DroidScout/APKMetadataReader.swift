import Foundation

struct APKMetadata: Sendable {
    var packageName: String?
    var versionName: String?
    var versionCode: String?
    var label: String?
}

enum APKMetadataReader {
    static func read(path: String) -> APKMetadata? {
        read(path: path, toolPaths: toolCandidates())
    }

    static func read(path: String, toolPaths: [String]) -> APKMetadata? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        for toolPath in toolPaths {
            let result = ProcessRunner.runSync(
                executablePath: toolPath,
                arguments: ["dump", "badging", path],
                timeout: 10
            )
            guard result.succeeded, let metadata = parseBadging(result.stdout) else {
                continue
            }
            return metadata
        }
        return nil
    }

    static func parseBadging(_ text: String) -> APKMetadata? {
        guard let packageLine = text.split(separator: "\n").first(where: { $0.hasPrefix("package:") }) else {
            return nil
        }

        let packageText = String(packageLine)
        let labelLine = text.split(separator: "\n").first(where: { $0.hasPrefix("application-label:") }).map(String.init)

        return APKMetadata(
            packageName: attribute("name", in: packageText),
            versionName: attribute("versionName", in: packageText),
            versionCode: attribute("versionCode", in: packageText),
            label: labelLine.flatMap { quotedValue(in: $0) }
        )
    }

    private static func toolCandidates() -> [String] {
        var candidates: [String] = []
        let environment = ProcessInfo.processInfo.environment

        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = environment[key]?.nilIfBlank {
                candidates.append(contentsOf: buildToolsCandidates(root: root))
            }
        }

        candidates.append(contentsOf: buildToolsCandidates(root: "~/Library/Android/sdk"))

        let pathValue = environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for directory in pathValue.split(separator: ":") {
            candidates.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("aapt2").pathString)
            candidates.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("aapt").pathString)
        }

        var seen = Set<String>()
        return candidates
            .map { ($0 as NSString).expandingTildeInPath }
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
            .filter { seen.insert($0).inserted }
    }

    private static func buildToolsCandidates(root: String) -> [String] {
        let buildToolsURL = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
            .appendingPathComponent("build-tools", isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: buildToolsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return versions
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            .flatMap { versionURL in
                [
                    versionURL.appendingPathComponent("aapt2").pathString,
                    versionURL.appendingPathComponent("aapt").pathString
                ]
            }
    }

    private static func attribute(_ name: String, in text: String) -> String? {
        let prefix = "\(name)='"
        guard let start = text.range(of: prefix) else { return nil }
        let remainder = text[start.upperBound...]
        guard let end = remainder.firstIndex(of: "'") else { return nil }
        return String(remainder[..<end]).nilIfBlank
    }

    private static func quotedValue(in text: String) -> String? {
        guard let start = text.firstIndex(of: "'") else { return nil }
        let remainder = text[text.index(after: start)...]
        guard let end = remainder.firstIndex(of: "'") else { return nil }
        return String(remainder[..<end]).nilIfBlank
    }
}
