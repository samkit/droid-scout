import AppKit
import SwiftUI

public enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case projects
    case logs
    case updates
    case advanced

    public var id: String { rawValue }
}

public struct DroidScoutSettingsView: View {
    @ObservedObject var model: DroidScoutModel
    @State private var selectedTab: SettingsTab

    public init(model: DroidScoutModel, initialTab: SettingsTab = .general) {
        self.model = model
        _selectedTab = State(initialValue: initialTab)
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            DroidScoutSettingsPaneView(model: model, tab: .general)
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag(SettingsTab.general)

            DroidScoutSettingsPaneView(model: model, tab: .projects)
            .tabItem { Label("Projects", systemImage: "folder") }
            .tag(SettingsTab.projects)

            DroidScoutSettingsPaneView(model: model, tab: .logs)
            .tabItem { Label("Logs", systemImage: "terminal") }
            .tag(SettingsTab.logs)

            DroidScoutSettingsPaneView(model: model, tab: .updates)
            .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            .tag(SettingsTab.updates)

            DroidScoutSettingsPaneView(model: model, tab: .advanced)
            .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            .tag(SettingsTab.advanced)
        }
        .padding(20)
        .frame(width: 680, height: 500)
    }
}

struct DroidScoutSettingsPaneView: View {
    @ObservedObject var model: DroidScoutModel
    var tab: SettingsTab

    var body: some View {
        SettingsPane {
            switch tab {
            case .general:
                generalSettings
            case .projects:
                projectSettings
            case .logs:
                logSettings
            case .updates:
                updateSettings
            case .advanced:
                advancedSettings
            }
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection(title: "App") {
                SettingsRow("Launch at login") {
                    Toggle("", isOn: Binding {
                        model.settings.launchAtLogin
                    } set: { value in
                        model.setLaunchAtLoginEnabled(value)
                    })
                    .labelsHidden()
                    .help("Start Droid Scout automatically when you log in")
                }
            }

            SettingsSection(title: "ADB") {
                SettingsRow("Detected path") {
                    Text(model.adbStatus.path ?? "Not found")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .foregroundStyle(model.adbStatus.isHealthy ? .primary : .secondary)
                }

                if let custom = model.settings.customADBPath {
                    SettingsRow("Custom path") {
                        Text(custom)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                SettingsRow("") {
                    HStack(spacing: 8) {
                        Button("Choose ADB...", action: model.chooseADB)
                        Button("Retry Detection", action: model.retryADBDetection)
                        Button("Clear Custom Path", action: model.clearCustomADBPathAndRetry)
                        .disabled(model.settings.customADBPath == nil)
                    }
                }

                if !model.adbStatus.isHealthy {
                    SettingsRow("Install hint") {
                        HStack(spacing: 8) {
                            Text("brew install android-platform-tools")
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Button(action: model.copyHomebrewInstallHint) {
                                Image(systemName: "doc.on.doc")
                            }
                            .help("Copy install hint")
                        }
                    }
                }
            }

            SettingsSection(title: "Screen Mirroring (scrcpy)") {
                SettingsRow("Detected path") {
                    Text(ScrcpyLocator.locate(customPath: model.settings.customScrcpyPath) ?? "Not found")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .foregroundStyle(ScrcpyLocator.locate(customPath: model.settings.customScrcpyPath) != nil ? .primary : .secondary)
                }

                if let custom = model.settings.customScrcpyPath {
                    SettingsRow("Custom path") {
                        Text(custom)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                SettingsRow("") {
                    HStack(spacing: 8) {
                        Button("Choose scrcpy...", action: model.chooseScrcpy)
                        Button("Retry Detection", action: model.retryScrcpyDetection)
                        Button("Clear Custom Path", action: model.clearCustomScrcpyPath)
                        .disabled(model.settings.customScrcpyPath == nil)
                    }
                }

                if ScrcpyLocator.locate(customPath: model.settings.customScrcpyPath) == nil {
                    SettingsRow("Install hint") {
                        HStack(spacing: 8) {
                            Text("brew install scrcpy")
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Button(action: model.copyScrcpyInstallHint) {
                                Image(systemName: "doc.on.doc")
                            }
                            .help("Copy install hint")
                        }
                    }
                }
            }
        }
    }

    private var projectSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection(title: "Watched Android Projects") {
                HStack(spacing: 8) {
                    Button("Add...", action: model.addProjectFolder)
                    Button("Scan Now", action: model.scanProjectsFromUI)
                    Spacer()
                }

                if model.settings.watchedProjectPaths.isEmpty {
                    EmptySettingsMessage("No project folders configured.")
                } else {
                    VStack(spacing: 6) {
                        ForEach(model.settings.watchedProjectPaths, id: \.self) { path in
                            ProjectPathRow(path: path) {
                                model.removeProjectFolder(path)
                            }
                        }
                    }
                }
            }

            SettingsSection(title: "Detected Packages") {
                let packageArtifacts = model.artifacts.filter { $0.packageName != nil }
                if packageArtifacts.isEmpty {
                    EmptySettingsMessage("No APK metadata detected yet.")
                } else {
                    VStack(spacing: 6) {
                        ForEach(packageArtifacts.prefix(30)) { artifact in
                            PackageArtifactRow(artifact: artifact)
                        }
                    }
                }
            }
        }
    }

    private var logSettings: some View {
        SettingsSection(title: "Logs") {
            SettingsRow("Default target") {
                Picker("", selection: binding(\.logTarget)) {
                    ForEach(LogTarget.allCases) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                .labelsHidden()
                .frame(width: 180, alignment: .leading)
            }

            SettingsRow("Retention") {
                HStack(spacing: 10) {
                    Text("\(model.settings.logRetentionDays) days")
                        .monospacedDigit()
                        .frame(width: 64, alignment: .leading)
                    Stepper("", value: binding(\.logRetentionDays), in: 1...90)
                        .labelsHidden()
                }
            }

            SettingsRow("") {
                Button("Reveal Logs Folder", action: model.revealLogs)
            }
        }
    }

    private var updateSettings: some View {
        SettingsSection(title: "Updates") {
            SettingsRow("Background checks") {
                HStack(spacing: 12) {
                    Toggle("", isOn: binding(\.backgroundUpdateChecks))
                        .labelsHidden()
                    Button("Check for Updates...", action: model.checkForUpdates)
                    if model.restartAvailable {
                        Button("Restart to Apply Update", action: model.restartToApplyUpdate)
                    }
                }
            }

            if model.restartAvailable {
                SettingsRow("Installed update") {
                    Text("A newer app bundle is installed. Restart Droid Scout to switch to it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsRow("Release source") {
                Text("GitHub Releases. Sparkle can be connected when signing and appcast infrastructure are added.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection(title: "Notifications") {
                SettingsRow("Mode") {
                    Picker("", selection: binding(\.notificationMode)) {
                        ForEach(NotificationMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180, alignment: .leading)
                }
            }

            SettingsSection(title: "Package Tracking") {
                SettingsRow("Polling interval") {
                    HStack(spacing: 10) {
                        Text("\(Int(model.settings.packagePollingInterval)) seconds")
                            .monospacedDigit()
                            .frame(width: 86, alignment: .leading)
                        Stepper("", value: binding(\.packagePollingInterval), in: 10...60, step: 1)
                            .labelsHidden()
                    }
                }

                SettingsRow("Confidence threshold") {
                    Picker("", selection: binding(\.confidenceThreshold)) {
                        ForEach(DeployConfidence.allCases, id: \.rawValue) { confidence in
                            Text(confidence.displayName).tag(confidence)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180, alignment: .leading)
                }
            }

            SettingsSection(title: "Diagnostics") {
                SettingsRow("") {
                    Button("Export Diagnostics...", action: model.exportDiagnostics)
                }
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding {
            model.settings[keyPath: keyPath]
        } set: { value in
            model.settings[keyPath: keyPath] = value
        }
    }
}

public struct DroidScoutInstallProgressView: View {
    @ObservedObject var model: DroidScoutModel

    public init(model: DroidScoutModel) {
        self.model = model
    }

    public var body: some View {
        SettingsPane {
            SettingsSection(title: "Install Progress") {
                HStack(spacing: 12) {
                    ProgressView(value: Double(completedCount), total: Double(max(model.installResults.count, 1)))
                        .frame(maxWidth: 280)
                    Text(summary)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Completed", action: model.clearCompletedInstallResults)
                    .disabled(completedCount == 0)
                }

                if model.installResults.isEmpty {
                    EmptySettingsMessage("No install jobs yet.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.installResults) { result in
                            InstallProgressRow(result: result, deviceName: deviceName(for: result.deviceSerial))
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 680, height: 460)
    }

    private var completedCount: Int {
        model.installResults.filter(\.status.isTerminal).count
    }

    private var activeCount: Int {
        model.installResults.filter { !$0.status.isTerminal }.count
    }

    private var summary: String {
        if model.installResults.isEmpty {
            return "Idle"
        }
        if activeCount > 0 {
            return "\(activeCount) active, \(completedCount) completed"
        }
        return "\(completedCount) completed"
    }

    private func deviceName(for serial: String) -> String {
        model.devices.first(where: { $0.serial == serial })?.friendlyName ?? serial
    }
}

private struct InstallProgressRow: View {
    var result: InstallResult
    var deviceName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.artifactName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(deviceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let artifactPath = result.artifactPath {
                        Text(artifactPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(result.status.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                    Text(result.completedAt ?? result.startedAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if result.status == .installing {
                ProgressView()
                    .controlSize(.small)
            }

            if let message = message {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(result.status == .failed ? .red : .secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy output")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var icon: String {
        switch result.status {
        case .queued: "clock"
        case .installing: "arrow.down.circle"
        case .success: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .skipped: "forward.circle"
        }
    }

    private var color: Color {
        switch result.status {
        case .queued: .secondary
        case .installing: .accentColor
        case .success: .green
        case .failed: .red
        case .skipped: .orange
        }
    }

    private var message: String? {
        result.stderr.nilIfBlank ?? result.stdout.nilIfBlank
    }
}

private struct SettingsPane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(.top, 4)
            .padding(.horizontal, 2)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SettingsSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProjectPathRow: View {
    var path: String
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(path)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                remove()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove project")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct PackageArtifactRow: View {
    var artifact: ArtifactRecord

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: artifact.kind == .aab ? "shippingbox" : "app.badge")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.packageName ?? artifact.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(artifact.versionSummary) - \(artifact.kind.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct EmptySettingsMessage: View {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }
}

private struct SettingsRow<Content: View>: View {
    private let label: String
    @ViewBuilder private let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 142, alignment: .trailing)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
