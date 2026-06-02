import AppKit
import CoreImage
import Foundation
import Security

/// Immutable value type holding the three pieces needed for the Android Wireless Debugging QR pairing flow.
public struct QRPairingCredentials: Equatable, Sendable {
    public let serviceName: String
    public let password: String
    public let payload: String
}

/// Generates the QR code payload and image for the standard Android "Pair device with QR code" flow.
///
/// Payload format (exactly as specified by Android):
///   WIFI:T:ADB;S:<service-name>;P:<password>;;
///
/// The service name is used by the phone to advertise `_adb-tls-pairing._tcp`.
/// The password is fed to `adb pair <addr> <password>`.
///
/// A test hook (`DROID_SCOUT_TEST_QR_FIXED=1` in the environment) returns deterministic
/// values so integration tests can script exact `adb mdns services` + pair responses.
public enum PairingQRGenerator {
    private static let testEnvKey = "DROID_SCOUT_TEST_QR_FIXED"

    // Deterministic values used by integration tests when DROID_SCOUT_TEST_QR_FIXED=1.
    // These must match the expectations in the honest unit tests.
    private static let testServiceName = "droidscout-test"
    private static let testPassword = "fixed123456"

    /// Returns a fresh set of credentials (or the fixed test pair when the env var is set).
    public static func randomCredentials() -> QRPairingCredentials {
        if ProcessInfo.processInfo.environment[testEnvKey] == "1" {
            return QRPairingCredentials(
                serviceName: testServiceName,
                password: testPassword,
                payload: payload(from: testServiceName, password: testPassword)
            )
        }

        let service = "droidscout-" + randomHex(byteCount: 4)
        let pass = randomHex(byteCount: 6)
        return QRPairingCredentials(
            serviceName: service,
            password: pass,
            payload: payload(from: service, password: pass)
        )
    }

    /// Builds the exact wire-format payload string.
    public static func payload(from serviceName: String, password: String) -> String {
        "WIFI:T:ADB;S:\(serviceName);P:\(password);;"
    }

    /// Generates a crisp, scannable QR code image using the built-in Core Image generator.
    /// Returns nil only on catastrophic failure (should be rare).
    public static func generateQRCodeImage(payload: String, scale: CGFloat = 8) -> NSImage? {
        guard !payload.isEmpty,
              let data = payload.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else { return nil }

        // Scale up for phone camera readability (no interpolation artifacts).
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Reliable CGImage path for NSImage.
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }

        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let nsImage = NSImage(cgImage: cgImage, size: size)
        return nsImage
    }

    // MARK: - Helpers

    private static func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            // Extremely unlikely fallback — still produces valid (non-empty) values.
            return String((0..<byteCount * 2).map { _ in "0123456789abcdef".randomElement()! })
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
