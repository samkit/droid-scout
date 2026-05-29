import AppKit

public struct StatusItemPresentation {
    public var title: String
    public var toolTip: String
    public var tintColor: NSColor?
}

public enum StatusItemPresenter {
    public static func presentation(devices: [AndroidDevice], adbStatus: ADBAvailability) -> StatusItemPresentation {
        let onlineCount = devices.filter { $0.state == .online }.count
        let hasWarning = devices.contains { $0.state == .unauthorized || $0.state == .offline }
        return StatusItemPresentation(
            title: onlineCount > 0 ? " \(onlineCount)" : "",
            toolTip: tooltip(devices: devices, adbStatus: adbStatus),
            tintColor: !adbStatus.isHealthy ? .systemRed : (hasWarning ? .systemOrange : nil)
        )
    }

    private static func tooltip(devices: [AndroidDevice], adbStatus: ADBAvailability) -> String {
        switch adbStatus {
        case .checking:
            return "\(AppConstants.appName): checking ADB"
        case .missing, .failed:
            return "\(AppConstants.appName): ADB setup required"
        case .healthy:
            let online = devices.filter { $0.state == .online }.count
            let warning = devices.filter { $0.state == .unauthorized || $0.state == .offline }.count
            if warning > 0 {
                return "\(AppConstants.appName): \(online) online, \(warning) need attention"
            }
            return "\(AppConstants.appName): \(online) online"
        }
    }
}
