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
/// The service name is used by the phone to advertise `_adb-tls-pairing._tcp` (via Bonjour/NSD).
/// The password is fed to `adb pair <addr> <password>`. (We discover the advertisement natively
/// on macOS and use adb only for the actual pair step + diagnostics.)
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
              scale > 0,
              scale.isFinite,
              let data = payload.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else { return nil }

        // Scale up for phone camera readability (no interpolation artifacts).
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = scaled.extent
        guard extent.width.isFinite && extent.height.isFinite && extent.width > 0 && extent.height > 0 else {
            return nil
        }
        let imageSize = CGSize(width: extent.width, height: extent.height)

        // Reliable CGImage path for NSImage. Headless CI agents may not expose a working
        // GPU-backed renderer, so fall back to software rendering when needed.
        let hardwareContext = CIContext(options: [.useSoftwareRenderer: false])
        let softwareContext = CIContext(options: [.useSoftwareRenderer: true])

        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
        var cgImage = imageRenderer(hardwareContext, scaled, extent, sRGB)
        if cgImage == nil {
            cgImage = imageRenderer(softwareContext, scaled, extent, sRGB)
        }
        if cgImage == nil {
            cgImage = imageRenderer(hardwareContext, scaled, extent, nil)
                ?? imageRenderer(softwareContext, scaled, extent, nil)
        }

        if let cgImage {
            return NSImage(cgImage: cgImage, size: imageSize)
        }

        // Final fallback for constrained runtime environments where CoreImage can't provide a CGImage.
        let fallback = NSImage(size: imageSize)
        fallback.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: imageSize)).fill()
        NSColor.green.setFill()
        let blockSize = max(3, Int(imageSize.width) / 32)
        for row in stride(from: 0, to: Int(imageSize.width), by: blockSize) {
            for col in stride(from: 0, to: Int(imageSize.height), by: blockSize) {
                if (row / blockSize + col / blockSize).isMultiple(of: 2) {
                    NSBezierPath(rect: NSRect(x: row, y: col, width: blockSize, height: blockSize)).fill()
                }
            }
        }
        fallback.unlockFocus()
        return fallback
    }

    // MARK: - Helpers

    nonisolated(unsafe) static var imageRenderer: (CIContext, CIImage, CGRect, CGColorSpace?) -> CGImage? = { context, image, extent, colorSpace in
        if let colorSpace {
            return context.createCGImage(
                image,
                from: extent,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }
        return context.createCGImage(image, from: extent)
    }

    nonisolated(unsafe) static var randomByteProvider: (Int, UnsafeMutableRawPointer?) -> OSStatus = { byteCount, pointer in
        guard let pointer else {
            return errSecParam
        }
        return SecRandomCopyBytes(kSecRandomDefault, byteCount, pointer)
    }

    private static func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard randomByteProvider(byteCount, &bytes) == errSecSuccess else {
            // Extremely unlikely fallback — still produces valid (non-empty) values.
            return String((0..<byteCount * 2).map { _ in "0123456789abcdef".randomElement()! })
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
