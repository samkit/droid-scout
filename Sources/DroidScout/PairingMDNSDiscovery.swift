import Foundation
import Darwin

/// Discovers an _adb-tls-pairing._tcp Bonjour service by exact instance name (the S: value from the QR payload).
/// This is used for the QR pairing flow so we are not dependent on `adb mdns services` output/format/timing.
/// When the phone scans the QR it advertises the pairing service using the requested instance name.
final class PairingMDNSDiscoverer: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    private let browser = NetServiceBrowser()
    private var targetName: String?
    private var continuation: CheckedContinuation<DiscoveredPairingService?, Never>?
    private var resolvedServices: [NetService] = []
    private var timeoutTask: Task<Void, Never>?

    struct DiscoveredPairingService: Sendable {
        let address: String
        let instanceName: String
    }

    /// Returns the first matching pairing service (addr + the exact instance name reported by Bonjour), or nil on timeout/cancel.
    /// We log the exact instanceName so we can compare against the S: value we put in the QR.
    func discover(serviceName: String, timeout: TimeInterval) async -> DiscoveredPairingService? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<DiscoveredPairingService?, Never>) in
                self.continuation = cont
                Task { @MainActor in
                    self.targetName = serviceName
                    self.browser.delegate = self
                    self.browser.searchForServices(ofType: "_adb-tls-pairing._tcp.", inDomain: "local.")
                self.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    self?.finish(with: nil)
                }
            }
        }
        } onCancel: { [weak self] in
            self?.finish(with: nil)
        }
    }

    func cancel() {
        finish(with: nil)
    }

    private func finish(with result: DiscoveredPairingService?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        // Stop on main to match how browser was scheduled.
        Task { @MainActor in
            self.browser.stop()
            for svc in self.resolvedServices {
                svc.stop()
            }
            self.resolvedServices.removeAll()
        }
        let cont = continuation
        continuation = nil
        targetName = nil
        cont?.resume(returning: result)
    }

    // MARK: - NetServiceBrowserDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        // Match instance name defensively: normalize casing and trailing punctuation.
        // Some adb/Bonjour stacks emit subtle naming differences even for the same logical service.
        guard serviceMatchesTarget(service.name) else { return }
        service.delegate = self
        resolvedServices.append(service)
        service.resolve(withTimeout: 10.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        // If the one we care about goes away before resolve, just let timeout handle.
        resolvedServices.removeAll { $0 == service }
    }

    // MARK: - NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard serviceMatchesTarget(sender.name) else { return }
        if let addr = hostPort(from: sender) {
            let matched = DiscoveredPairingService(address: addr, instanceName: sender.name)
            finish(with: matched)
        }
        // If no usable address, keep waiting (timeout will fire) or other instances may appear.
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        // Resolution failed for this instance; continue waiting for it (or timeout).
        // The phone may re-advertise.
    }

    // MARK: - Helpers

    private func serviceMatchesTarget(_ discoveredName: String) -> Bool {
        guard let targetName else { return false }
        let normalizedDiscovered = Self.normalizeServiceName(discoveredName)
        let normalizedTarget = Self.normalizeServiceName(targetName)
        guard !normalizedDiscovered.isEmpty && !normalizedTarget.isEmpty else { return false }
        return normalizedDiscovered == normalizedTarget
    }

    private static func normalizeServiceName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private func hostPort(from service: NetService) -> String? {
        let port = service.port
        // Prefer the hostname reported by the service (SRV target, usually ends in .local).
        // This often works better than a raw IP from the A record in complex networks
        // (multiple interfaces, mDNS resolution picking the right path, etc.).
        // adb pair accepts host:port and will resolve via the system resolver (Bonjour).
        if let host = service.hostName, !host.isEmpty {
            // Strip trailing dot (mDNS/Bonjour FQDNs often end with ".") so we produce clean
            // "name.local:port" instead of "name.local.:port" which can confuse adb pair parsing
            // or the device-side pairing protocol status exchange.
            let cleanHost = host.hasSuffix(".") ? String(host.dropLast()) : host
            if cleanHost.contains(":") && !cleanHost.hasPrefix("[") {
                return "[\(cleanHost)]:\(port)"
            }
            return "\(cleanHost):\(port)"
        }

        // Fallback to numeric IP from the resolved address records.
        guard let addresses = service.addresses, !addresses.isEmpty else {
            return nil
        }

        for addressData in addresses {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let success = addressData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
                guard let base = buffer.baseAddress else { return false }
                let addrPtr = base.assumingMemoryBound(to: sockaddr.self)
                let res = getnameinfo(addrPtr, socklen_t(addressData.count), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                return res == 0
            }
            if success {
                let ip = hostname.withUnsafeBufferPointer { buf -> String in
                    buf.withMemoryRebound(to: UInt8.self) { u8 in
                        if let term = u8.firstIndex(of: 0) {
                            return String(decoding: u8[..<term], as: UTF8.self)
                        }
                        return String(decoding: u8, as: UTF8.self)
                    }
                }
                if ip.contains(":") && !ip.hasPrefix("[") {
                    return "[\(ip)]:\(port)"
                }
                return "\(ip):\(port)"
            }
        }
        return nil
    }
}
