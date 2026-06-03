import Foundation
import Testing
import Darwin
@testable import DroidScout

@Test func adbDeviceParserExtractsStatesModelsAndTransportHints() {
    let output = """
    List of devices attached
    emulator-5554\tdevice product:sdk_gphone64 model:sdk_gphone64_arm64 device:emu transport_id:1
    192.168.1.10:5555 device product:oriole model:Pixel_6 transport_id:2
    R58T12345 unauthorized usb:336592896X
    broken-line
    USB987 offline model:OnePlus_12 usb:1-1
    weird recovery model:Mystery_Box
    """

    let devices = ADBDeviceParser.parseDevices(output)
    #expect(devices.map(\.serial) == ["emulator-5554", "192.168.1.10:5555", "R58T12345", "USB987", "weird"])
    #expect(devices[0].state == .online)
    #expect(devices[0].modelHint == "sdk gphone64 arm64")
    #expect(devices[0].transportHint == nil)
    #expect(devices[1].transportHint == "Wi-Fi")
    #expect(devices[2].state == .unauthorized)
    #expect(devices[2].transportHint == "USB")
    #expect(devices[3].state == .offline)
    #expect(devices[4].state == .unknown)
}

@Test func avdMergerMatchesRunningEmulatorsAddsStoppedAVDsAndSortsByState() {
    let physical = TestSupport.device(serial: "USB1", state: .online, friendlyName: "Physical")
    let unauthorized = TestSupport.device(serial: "USB2", state: .unauthorized, friendlyName: "Needs Auth")
    let runningWithoutAVD = TestSupport.device(
        serial: "emulator-5554",
        state: .online,
        friendlyName: "Pixel 8 API 35",
        transportHint: "Emulator",
        avdName: nil
    )

    let merged = AVDDeviceMerger.mergeAVDs(
        ["Pixel_8_API_35", "Tablet_API_34", "Pixel_8_API_35_Extended"],
        into: [unauthorized, runningWithoutAVD, physical]
    )

    #expect(merged.map(\.state) == [.online, .online, .unauthorized, .stopped])
    #expect(merged.contains { $0.serial == "USB1" })
    let running = merged.first { $0.serial == "emulator-5554" }
    #expect(running?.friendlyName == "Pixel_8_API_35")
    #expect(running?.avdName == "Pixel_8_API_35")
    #expect(merged.contains { $0.serial == "avd:Tablet_API_34" && $0.canStartEmulator })
    #expect(!merged.contains { $0.serial == "avd:Pixel_8_API_35_Extended" })
}

@Test func avdMergerPrefersRunningAndNamedEmulatorsWhenDeduplicating() {
    let stopped = TestSupport.device(
        serial: "avd:Pixel_API_35",
        state: .stopped,
        friendlyName: "Pixel_API_35",
        transportHint: "Emulator",
        avdName: "Pixel_API_35"
    )
    let runningUnnamed = TestSupport.device(
        serial: "emulator-5554",
        state: .online,
        friendlyName: "Pixel API 35",
        transportHint: "Emulator",
        avdName: nil
    )
    let punctuationOnly = TestSupport.device(
        serial: "emulator-5560",
        state: .online,
        friendlyName: "___",
        transportHint: "Emulator",
        avdName: "___"
    )

    let merged = AVDDeviceMerger.mergeAVDs(
        ["Pixel_API_35"],
        into: [stopped, runningUnnamed, punctuationOnly]
    )

    #expect(merged.contains { $0.serial == "emulator-5554" })
    #expect(!merged.contains { $0.serial == "avd:Pixel_API_35" })
    #expect(merged.contains { $0.serial == "emulator-5560" })

    let runningNamed = TestSupport.device(
        serial: "emulator-5556",
        state: .online,
        friendlyName: "Pixel_API_36",
        transportHint: "Emulator",
        avdName: "Pixel_API_36"
    )
    let runningUnnamedDuplicate = TestSupport.device(
        serial: "emulator-5558",
        state: .online,
        friendlyName: "Pixel API 36",
        transportHint: "Emulator",
        avdName: nil
    )
    let dedupedNamed = AVDDeviceMerger.mergeAVDs([], into: [runningUnnamedDuplicate, runningNamed])
    #expect(dedupedNamed.contains { $0.serial == "emulator-5556" })
    #expect(!dedupedNamed.contains { $0.serial == "emulator-5558" })

    let stoppedDuplicate = TestSupport.device(
        serial: "avd:Pixel_API_36",
        state: .stopped,
        friendlyName: "Pixel_API_36",
        transportHint: "Emulator",
        avdName: "Pixel_API_36"
    )
    let runningBeatsStopped = AVDDeviceMerger.mergeAVDs([], into: [runningNamed, stoppedDuplicate])
    #expect(runningBeatsStopped.contains { $0.serial == "emulator-5556" })
    #expect(!runningBeatsStopped.contains { $0.serial == "avd:Pixel_API_36" })

    let firstNamed = TestSupport.device(
        serial: "emulator-5562",
        state: .online,
        friendlyName: "Pixel_API_37",
        transportHint: "Emulator",
        avdName: "Pixel_API_37"
    )
    let secondNamed = TestSupport.device(
        serial: "emulator-5564",
        state: .online,
        friendlyName: "Pixel API 37",
        transportHint: "Emulator",
        avdName: "Pixel_API_37"
    )
    let firstNamedWinsTie = AVDDeviceMerger.mergeAVDs([], into: [firstNamed, secondNamed])
    #expect(firstNamedWinsTie.contains { $0.serial == "emulator-5562" })
    #expect(!firstNamedWinsTie.contains { $0.serial == "emulator-5564" })
}

@Test func adbLocatorValidatesCustomExecutableWithRealProcess() async throws {
    let temp = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(temp) }

    let workingADB = temp.appendingPathComponent("adb-ok")
    try TestSupport.executableScript(workingADB, body: """
    if [ "$1" = "version" ]; then
      echo "Android Debug Bridge version 35.0.2"
      echo "extra line"
      exit 0
    fi
    exit 64
    """)

    let healthy = await ADBLocator().locate(customPath: workingADB.pathString)
    guard case let .healthy(path, version) = healthy else {
        Issue.record("Expected custom ADB to validate")
        return
    }
    #expect(path == workingADB.pathString)
    #expect(version == "Android Debug Bridge version 35.0.2")

    let failingADB = temp.appendingPathComponent("adb-fail")
    try TestSupport.executableScript(failingADB, body: """
    echo "custom adb failed" >&2
    exit 3
    """)

    let failed = await ADBLocator().locate(customPath: failingADB.pathString)
    guard case let .failed(path, message) = failed else {
        Issue.record("Expected custom ADB failure to be reported before fallback paths")
        return
    }
    #expect(path == failingADB.pathString)
    #expect(message == "custom adb failed")
}

@Test func adbLocatorReportsMissingWhenNoCandidateIsExecutable() async {
    let missing = await ADBLocator(fileManager: NonExecutableFileManager()).locate(customPath: nil)
    guard case let .missing(message) = missing else {
        Issue.record("Expected ADB locator to report a missing install")
        return
    }
    #expect(message.contains("brew install android-platform-tools"))
}

@Test func adbClientAndEmulatorServiceUseRealExecutables() async throws {
    let temp = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(temp) }

    let sdk = temp.appendingPathComponent("sdk", isDirectory: true)
    let adb = sdk.appendingPathComponent("platform-tools/adb")
    let emulator = sdk.appendingPathComponent("emulator/emulator")

    try TestSupport.executableScript(adb, body: """
    if [ "$1" = "devices" ]; then
      echo "List of devices attached"
      echo "USB1 device model:Pixel_8 usb:1"
      exit 0
    fi
    echo "$@"
    exit 0
    """)
    try TestSupport.executableScript(emulator, body: """
    if [ "$1" = "-list-avds" ]; then
      printf "Tablet_API_34\\nPixel_8_API_35\\n\\n"
      exit 0
    fi
    exit 0
    """)

    let client = ADBClient(adbPath: adb.pathString)
    let result = await client.run(serial: "USB1", arguments: ["shell", "id"], timeout: 5)
    #expect(result.succeeded)
    #expect(result.stdout == "-s USB1 shell id\n")
    let devices = await client.listDevices()
    #expect(devices.count == 1)
    #expect(devices.first?.modelHint == "Pixel 8")

    let service = EmulatorService(adbPath: adb.pathString)
    #expect(service.isAvailable)
    #expect(await service.listAVDs() == ["Pixel_8_API_35", "Tablet_API_34"])
    try service.startAVD(named: "Pixel_8_API_35")

    let missingService = EmulatorService(
        adbPath: temp.appendingPathComponent("standalone-adb").pathString,
        fileManager: NonExecutableFileManager()
    )
    #expect(!missingService.isAvailable)
    #expect(await missingService.listAVDs().isEmpty)
    #expect(throws: EmulatorServiceError.self) {
        try missingService.startAVD(named: "Missing_API")
    }
    #expect(EmulatorServiceError.emulatorNotFound.localizedDescription == "The Android Emulator tool was not found in the detected SDK.")
}

@Test func deviceInfoServiceHydratesPhysicalEmulatorOfflineAndFallbackNames() async throws {
    let temp = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(temp) }

    let adb = temp.appendingPathComponent("adb")
    try TestSupport.executableScript(adb, body: """
    if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "getprop" ] && [ "$2" = "USB-SAMSUNG" ]; then
      cat <<'PROPS'
    [ro.product.manufacturer]: [samsung]
    [ro.product.model]: [SM-S928U]
    [ro.build.version.release]: [15]
    [ro.build.version.sdk]: [35]
    PROPS
      exit 0
    fi
    if [ "$1" = "-s" ] && [ "$3" = "emu" ] && [ "$4" = "avd" ]; then
      printf "Pixel_API_35\\nOK\\n"
      exit 0
    fi
    if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "getprop" ] && [ "$2" = "emulator-5554" ]; then
      cat <<'PROPS'
    [ro.boot.qemu.avd_name]: [Pixel_API_35]
    [ro.build.version.release]: [14]
    [ro.build.version.sdk]: [34]
    PROPS
      exit 0
    fi
    exit 0
    """)

    let service = DeviceInfoService(adbClient: ADBClient(adbPath: adb.pathString))
    let devices = await service.hydrate([
        DeviceSnapshot(serial: "offline-1", state: .offline, modelHint: nil, transportHint: "USB"),
        DeviceSnapshot(serial: "USB-SAMSUNG", state: .online, modelHint: "Fallback_Model", transportHint: "USB"),
        DeviceSnapshot(serial: "emulator-5554", state: .online, modelHint: "sdk_gphone", transportHint: nil),
        DeviceSnapshot(serial: "unauth-1", state: .unauthorized, modelHint: "Needs_Auth", transportHint: "USB")
    ], cachedNames: ["offline-1": "Cached Offline"])

    #expect(devices.map(\.state) == [.online, .online, .unauthorized, .offline])
    #expect(devices.first { $0.serial == "USB-SAMSUNG" }?.friendlyName == "Samsung Galaxy S24 Ultra")
    #expect(devices.first { $0.serial == "USB-SAMSUNG" }?.versionSummary == "Android 15 / API 35")
    #expect(devices.first { $0.serial == "emulator-5554" }?.avdName == "Pixel API 35")
    #expect(devices.first { $0.serial == "offline-1" }?.friendlyName == "Cached Offline")
    #expect(devices.first { $0.serial == "unauth-1" }?.friendlyName == "Needs_Auth")
}

@Test func deviceInfoServiceReadsRunningAVDNameFromEmuAndSingleGetpropFallbacks() async throws {
    let temp = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(temp) }

    let adb = temp.appendingPathComponent("adb")
    try TestSupport.executableScript(adb, body: """
    if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "getprop" ]; then
      if [ "$5" = "ro.boot.qemu.avd_name" ] && [ "$2" = "emulator-5556" ]; then
        echo "Fallback_API_36"
        exit 0
      fi
      if [ -z "$5" ]; then
        echo "[ro.product.manufacturer]: [Google]"
        echo "[ro.product.model]: [Pixel 9]"
        exit 0
      fi
      exit 1
    fi
    if [ "$1" = "-s" ] && [ "$3" = "emu" ] && [ "$4" = "avd" ] && [ "$5" = "name" ]; then
      if [ "$2" = "emulator-5554" ]; then
        printf "\\nRunning_API_35\\nOK\\n"
        exit 0
      fi
      exit 1
    fi
    exit 0
    """)

    let service = DeviceInfoService(adbClient: ADBClient(adbPath: adb.pathString))
    let devices = await service.hydrate([
        DeviceSnapshot(serial: "emulator-5554", state: .online, modelHint: "sdk phone", transportHint: nil),
        DeviceSnapshot(serial: "emulator-5556", state: .online, modelHint: "sdk tablet", transportHint: nil)
    ], cachedNames: [:])

    #expect(devices.first { $0.serial == "emulator-5554" }?.avdName == "Running_API_35")
    #expect(devices.first { $0.serial == "emulator-5556" }?.avdName == "Fallback_API_36")
}

private final class NonExecutableFileManager: FileManager, @unchecked Sendable {
    override func isExecutableFile(atPath path: String) -> Bool {
        false
    }
}

private final class FakeNetService: NetService {
    private let fakeName: String
    private let fakePort: Int
    private let fakeHostName: String?
    private let fakeAddresses: [Data]?

    init(name: String, port: Int, hostName: String? = nil, addresses: [Data]? = nil) {
        self.fakeName = name
        self.fakePort = port
        self.fakeHostName = hostName
        self.fakeAddresses = addresses
        super.init(domain: "local.", type: "_adb-tls-pairing._tcp.", name: name, port: Int32(port))
    }

    override var hostName: String? {
        fakeHostName
    }

    override var name: String {
        fakeName
    }

    override var port: Int {
        fakePort
    }

    override var addresses: [Data]? {
        fakeAddresses
    }
}

private func ipv4SockaddrData(_ address: String, port: UInt16) -> Data {
    var result = sockaddr_in()
    result.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    result.sin_family = sa_family_t(AF_INET)
    result.sin_port = in_port_t(port.bigEndian)
    _ = address.withCString { stringPointer in
        inet_pton(AF_INET, stringPointer, &result.sin_addr)
    }
    return withUnsafeBytes(of: result) { Data($0) }
}

private func ipv6SockaddrData(_ address: String, port: UInt16) -> Data {
    var result = sockaddr_in6()
    result.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    result.sin6_family = sa_family_t(AF_INET6)
    result.sin6_port = in_port_t(port.bigEndian)
    _ = address.withCString { stringPointer in
        inet_pton(AF_INET6, stringPointer, &result.sin6_addr)
    }
    return withUnsafeBytes(of: result) { Data($0) }
}

@MainActor
@Test func deviceTrackerReportsWatcherLaunchFailureAndStopsCleanly() async throws {
    let tracker = DeviceTracker()
    var watcherError: String?
    var snapshots: [[AndroidDevice]] = []
    tracker.onWatcherError = { watcherError = $0 }
    tracker.onDevicesChanged = { snapshots.append($0) }

    tracker.start(
        adbClient: ADBClient(adbPath: "/definitely/missing/adb"),
        emulatorService: nil,
        cachedNames: [:],
        interval: 60
    )
    #expect(tracker.watcherState != .running)
    #expect(watcherError?.isEmpty == false)

    await tracker.refresh()
    #expect(!snapshots.isEmpty && snapshots.allSatisfy { $0.isEmpty })
    tracker.stop()
    #expect(tracker.watcherState == .stopped)
}

@Test func apkMetadataReaderParsesBadgingAndReadsThroughAAPTProcess() throws {
    let badging = """
    package: name='com.example.scout' versionCode='42' versionName='2.4.1' platformBuildVersionName='15'
    sdkVersion:'23'
    application-label:'Droid Scout Fixture'
    """
    guard let parsed = APKMetadataReader.parseBadging(badging) else {
        Issue.record("Expected badging to parse")
        return
    }
    #expect(parsed.packageName == "com.example.scout")
    #expect(parsed.versionCode == "42")
    #expect(parsed.versionName == "2.4.1")
    #expect(parsed.label == "Droid Scout Fixture")
    #expect(APKMetadataReader.parseBadging("sdkVersion:'23'") == nil)

    let temp = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(temp) }
    let apk = temp.appendingPathComponent("app.apk")
    try TestSupport.touch(apk)

    let badTool = temp.appendingPathComponent("bad-aapt")
    try TestSupport.executableScript(badTool, body: "exit 2")

    let goodTool = temp.appendingPathComponent("aapt")
    try TestSupport.executableScript(goodTool, body: """
    if [ "$1" = "dump" ] && [ "$2" = "badging" ]; then
      echo "package: name='com.example.scout' versionCode='42' versionName='2.4.1'"
      echo "application-label:'Droid Scout Fixture'"
      exit 0
    fi
    exit 64
    """)

    guard let metadata = APKMetadataReader.read(path: apk.pathString, toolPaths: [badTool.pathString, goodTool.pathString]) else {
        Issue.record("Expected metadata to be read through fake aapt")
        return
    }
    #expect(metadata.packageName == "com.example.scout")
    #expect(metadata.versionName == "2.4.1")
    #expect(metadata.versionCode == "42")
    #expect(metadata.label == "Droid Scout Fixture")
    #expect(APKMetadataReader.read(path: temp.appendingPathComponent("missing.apk").pathString, toolPaths: [goodTool.pathString]) == nil)
}

@Test func apkMetadataReaderFallsBackToDefaultPathWhenPathVariableIsUnavailable() throws {
    let temp = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(temp) }

    let apk = temp.appendingPathComponent("app.apk")
    try TestSupport.touch(apk)

    let previousPath = ProcessInfo.processInfo.environment["PATH"]
    let previousAndroidHome = ProcessInfo.processInfo.environment["ANDROID_HOME"]
    let previousAndroidSDKRoot = ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"]

    unsetenv("PATH")
    unsetenv("ANDROID_HOME")
    unsetenv("ANDROID_SDK_ROOT")
    defer {
        if let previousPath = previousPath {
            setenv("PATH", previousPath, 1)
        } else {
            unsetenv("PATH")
        }
        if let previousAndroidHome = previousAndroidHome {
            setenv("ANDROID_HOME", previousAndroidHome, 1)
        } else {
            unsetenv("ANDROID_HOME")
        }
        if let previousAndroidSDKRoot = previousAndroidSDKRoot {
            setenv("ANDROID_SDK_ROOT", previousAndroidSDKRoot, 1)
        } else {
            unsetenv("ANDROID_SDK_ROOT")
        }
    }

    let metadata = APKMetadataReader.read(path: apk.pathString)
    #expect(metadata == nil)
}

// MARK: - QR Code Pairing Generator (Phase 1 TDD)

@Test func pairingQRGeneratorProducesValidPayloadAndCredentials() {
    let creds = PairingQRGenerator.randomCredentials()

    #expect(creds.serviceName.hasPrefix("droidscout-"))
    #expect(creds.serviceName.count >= 10)
    #expect(creds.password.count >= 8)
    #expect(creds.payload.hasPrefix("WIFI:T:ADB;S:"))
    #expect(creds.payload.contains(";P:"))
    #expect(creds.payload.hasSuffix(";;"))

    // Honest roundtrip reconstruction from the public fields proves the payload format is exactly what Android expects.
    let reconstructed = "WIFI:T:ADB;S:\(creds.serviceName);P:\(creds.password);;"
    #expect(creds.payload == reconstructed)
}

@Test func pairingQRGeneratorRespectsTestFixedCredentialsEnvVarForDeterministicTests() {
    setenv("DROID_SCOUT_TEST_QR_FIXED", "1", 1)
    defer { unsetenv("DROID_SCOUT_TEST_QR_FIXED") }

    let creds = PairingQRGenerator.randomCredentials()

    #expect(creds.serviceName == "droidscout-test")
    #expect(creds.password == "fixed123456")
    #expect(creds.payload == "WIFI:T:ADB;S:droidscout-test;P:fixed123456;;")
}

@Test func pairingQRGeneratorFallsBackToRandomHexWhenSecureRandomFails() {
    let previousProvider = PairingQRGenerator.randomByteProvider
    let previousFixedEnv = ProcessInfo.processInfo.environment["DROID_SCOUT_TEST_QR_FIXED"]
    PairingQRGenerator.randomByteProvider = { _, _ in -1 }
    unsetenv("DROID_SCOUT_TEST_QR_FIXED")
    defer {
        PairingQRGenerator.randomByteProvider = previousProvider
        if let previousFixedEnv {
            setenv("DROID_SCOUT_TEST_QR_FIXED", previousFixedEnv, 1)
        } else {
            unsetenv("DROID_SCOUT_TEST_QR_FIXED")
        }
    }

    let creds = PairingQRGenerator.randomCredentials()
    let hexDigits = Set("0123456789abcdefABCDEF".map(Character.init))

    #expect(creds.serviceName.hasPrefix("droidscout-"))
    #expect(creds.serviceName.count >= 10)
    #expect(creds.serviceName.dropFirst("droidscout-".count).unicodeScalars.allSatisfy { hexDigits.contains(Character($0)) })
    #expect(creds.password.count == 12)
    #expect(creds.password.unicodeScalars.allSatisfy { hexDigits.contains(Character($0)) })
}

@Test func pairingQREncodingHelpersAreConsistent() {
    let payload = PairingQRGenerator.payload(from: "unit-device", password: "unit-pass")
    #expect(payload == "WIFI:T:ADB;S:unit-device;P:unit-pass;;")
    #expect(PairingQRGenerator.generateQRCodeImage(payload: "", scale: 5) == nil)
}

@Test func pairingQRGeneratorRejectsInvalidScaleThatProducesNonFiniteImageBounds() {
    let payload = PairingQRGenerator.payload(from: "unit-device", password: "unit-pass")
    #expect(PairingQRGenerator.generateQRCodeImage(payload: payload, scale: 0) == nil)
}

@Test func pairingQRGeneratorRejectsNegativeScaleBeforeProducingImage() {
    let payload = PairingQRGenerator.payload(from: "unit-device", password: "unit-pass")
    #expect(PairingQRGenerator.generateQRCodeImage(payload: payload, scale: -1) == nil)
}

@Test func pairingQRGeneratorRejectsNonFiniteScaleBeforeProducingImage() {
    let payload = PairingQRGenerator.payload(from: "unit-device", password: "unit-pass")
    #expect(PairingQRGenerator.generateQRCodeImage(payload: payload, scale: .nan) == nil)
}

@Test func pairingQRGeneratorProducesUsableScannableQRCodeImage() {
    let payload = "WIFI:T:ADB;S:real-svc-xyz;P:real-pass-abc123;;"
    let image = PairingQRGenerator.generateQRCodeImage(payload: payload, scale: 6)

    #expect(image != nil, "CoreImage QR generator must produce an image for a valid payload")
    #expect(image!.size.width >= 150, "QR must be large enough for phone camera to scan reliably")
    #expect(image!.size.height >= 150)
    #expect(image!.tiffRepresentation != nil)
    #expect(image!.representations.isEmpty == false)
}

@Test func pairingQRGeneratorFallsBackToPatternImageWhenCoreImageRenderingFails() {
    let previousRenderer = PairingQRGenerator.imageRenderer
    PairingQRGenerator.imageRenderer = { _, _, _, _ in nil }
    defer { PairingQRGenerator.imageRenderer = previousRenderer }

    let payload = PairingQRGenerator.payload(from: "unit-device", password: "unit-pass")
    let image = PairingQRGenerator.generateQRCodeImage(payload: payload, scale: 6)

    #expect(image != nil, "Fallback renderer should still return a deterministic placeholder image")
    #expect(image!.size.width > 0)
    #expect(image!.size.height > 0)
    #expect(image!.representations.isEmpty == false)
}

@Test func pairingQRGeneratorRandomCredentialsCanUseInjectedRandomByteProvider() {
    let previousProvider = PairingQRGenerator.randomByteProvider
    let previousFixedEnv = ProcessInfo.processInfo.environment["DROID_SCOUT_TEST_QR_FIXED"]
    var callIndex = 0

    PairingQRGenerator.randomByteProvider = { byteCount, pointer in
        guard let pointer else { return errSecParam }
        let bytes = pointer.assumingMemoryBound(to: UInt8.self)
        for index in 0..<byteCount {
            bytes[index] = UInt8(index + callIndex * 4)
        }
        callIndex += 1
        return errSecSuccess
    }
    unsetenv("DROID_SCOUT_TEST_QR_FIXED")

    defer {
        PairingQRGenerator.randomByteProvider = previousProvider
        if let previousFixedEnv {
            setenv("DROID_SCOUT_TEST_QR_FIXED", previousFixedEnv, 1)
        } else {
            unsetenv("DROID_SCOUT_TEST_QR_FIXED")
        }
    }

    let creds = PairingQRGenerator.randomCredentials()

    #expect(creds.serviceName == "droidscout-00010203")
    #expect(creds.password == "040506070809")
    #expect(
        creds.payload ==
            "WIFI:T:ADB;S:droidscout-00010203;P:040506070809;;"
    )
}

@Test func pairingQRGeneratorHonorsFixedEnvOverInjectedRandomProvider() {
    let previousProvider = PairingQRGenerator.randomByteProvider
    let previousFixedEnv = ProcessInfo.processInfo.environment["DROID_SCOUT_TEST_QR_FIXED"]

    setenv("DROID_SCOUT_TEST_QR_FIXED", "1", 1)
    PairingQRGenerator.randomByteProvider = { _, _ in
        #expect(Bool(false), "Random provider should not be called when fixed test env is enabled")
        return -1
    }
    defer {
        PairingQRGenerator.randomByteProvider = previousProvider
        if let previousFixedEnv {
            setenv("DROID_SCOUT_TEST_QR_FIXED", previousFixedEnv, 1)
        } else {
            unsetenv("DROID_SCOUT_TEST_QR_FIXED")
        }
    }

    let creds = PairingQRGenerator.randomCredentials()
    #expect(creds.serviceName == "droidscout-test")
    #expect(creds.password == "fixed123456")
    #expect(creds.payload == "WIFI:T:ADB;S:droidscout-test;P:fixed123456;;")
}

@Test func pairingQRGeneratorRandomByteProviderReturnsErrorForNilBuffer() {
    #expect(PairingQRGenerator.randomByteProvider(8, nil) == errSecParam)
}

// MARK: - ADB mDNS Services Parser (Phase 2 TDD)

@Test func adbMdnsParserExtractsPairingServicesFromRealAdbOutput() {
    let output = """
    List of discovered mdns services
    droidscout-test-001\t_adb-tls-pairing._tcp\t192.168.1.42:37123
    studio-g@abc123\t_adb-tls-pairing._tcp\t10.0.0.5:12345
    other-device\t_adb-tls-connect._tcp\t192.168.1.99:5555
    droidscout-abc123\t_adb-tls-pairing._tcp\t[fe80::1]:40000
    malformed line here
    """

    let services = ADBMdnsParser.parseMdnsServices(output)

    #expect(services.count >= 3)
    let pairing = services.filter { $0.type == "_adb-tls-pairing._tcp" }
    #expect(pairing.count == 3)

    let first = pairing.first { $0.name == "droidscout-test-001" }
    #expect(first?.address == "192.168.1.42:37123")

    let ipv6 = pairing.first { $0.name == "droidscout-abc123" }
    #expect(ipv6?.address?.contains(":40000") == true)
}

@MainActor
@Test func pairingMDNSDiscovererResolvesMatchingHostServiceNameWithNormalizedInputs() async {
    let discoverer = PairingMDNSDiscoverer()
    let task = Task { await discoverer.discover(serviceName: "  DROIDSCOUT-SVC. ", timeout: 1.0) }
    try? await Task.sleep(for: .milliseconds(5))

    let service = FakeNetService(
        name: "droidscout-svc",
        port: 37123,
        hostName: "pairing-device.local."
    )

    discoverer.netServiceBrowser(
        NetServiceBrowser(),
        didFind: service,
        moreComing: false
    )
    discoverer.netServiceDidResolveAddress(service)

    let result = await task.value
    #expect(result?.address == "pairing-device.local:37123")
    #expect(result?.instanceName == "droidscout-svc")
}

@MainActor
@Test func pairingMDNSDiscovererResolvesMatchingHostServiceNameWithColonHost() async {
    let discoverer = PairingMDNSDiscoverer()
    let task = Task { await discoverer.discover(serviceName: " droidscout-colon ", timeout: 1.0) }
    try? await Task.sleep(for: .milliseconds(5))

    let service = FakeNetService(
        name: "droidscout-colon",
        port: 40000,
        hostName: "fe80::1"
    )

    discoverer.netServiceBrowser(
        NetServiceBrowser(),
        didFind: service,
        moreComing: false
    )
    discoverer.netServiceDidResolveAddress(service)

    let result = await task.value
    #expect(result?.address == "[fe80::1]:40000")
}

@MainActor
@Test func pairingMDNSDiscovererFallsBackToIPv4AddressWhenHostNameMissing() async {
    let discoverer = PairingMDNSDiscoverer()
    let task = Task { await discoverer.discover(serviceName: "droidscout-fallback-ipv4", timeout: 1.0) }
    try? await Task.sleep(for: .milliseconds(5))

    let service = FakeNetService(
        name: "droidscout-fallback-ipv4",
        port: 5555,
        hostName: nil,
        addresses: [ipv4SockaddrData("10.0.0.42", port: 5555)]
    )

    discoverer.netServiceBrowser(
        NetServiceBrowser(),
        didFind: service,
        moreComing: false
    )
    discoverer.netServiceDidResolveAddress(service)

    let result = await task.value
    #expect(result?.address == "10.0.0.42:5555")
}

@MainActor
@Test func pairingMDNSDiscovererFallsBackToIPv6AddressWhenHostNameMissing() async {
    let discoverer = PairingMDNSDiscoverer()
    let task = Task { await discoverer.discover(serviceName: "droidscout-fallback-ipv6", timeout: 1.0) }
    try? await Task.sleep(for: .milliseconds(5))

    let service = FakeNetService(
        name: "droidscout-fallback-ipv6",
        port: 44444,
        hostName: nil,
        addresses: [ipv6SockaddrData("2001:db8::1234", port: 44444)]
    )

    discoverer.netServiceBrowser(
        NetServiceBrowser(),
        didFind: service,
        moreComing: false
    )
    discoverer.netServiceDidResolveAddress(service)

    let result = await task.value
    #expect(result?.address == "[2001:db8::1234]:44444")
}

@MainActor
@Test func pairingMDNSDiscovererCancelsAndReturnsNilOnCancel() async {
    let discoverer = PairingMDNSDiscoverer()
    let task = Task { await discoverer.discover(serviceName: "droidscout-cancel", timeout: 2.0) }
    try? await Task.sleep(for: .milliseconds(5))
    task.cancel()

    let result = await task.value
    #expect(result == nil)
}

@MainActor
@Test func pairingMDNSDiscovererExplicitCancelMethodReturnsNil() async {
    let discoverer = PairingMDNSDiscoverer()
    let task = Task { await discoverer.discover(serviceName: "droidscout-explicit-cancel", timeout: 5.0) }
    try? await Task.sleep(for: .milliseconds(5))

    discoverer.cancel()

    let result = await task.value
    #expect(result == nil)
}

@MainActor
@Test func pairingMDNSDiscovererHandlesMatchedServiceWithNoHostAndNoAddressRecords() async {
    let discoverer = PairingMDNSDiscoverer()
    let task = Task { await discoverer.discover(serviceName: "droidscout-no-address", timeout: 0.08) }
    try? await Task.sleep(for: .milliseconds(5))

    let service = FakeNetService(name: "droidscout-no-address", port: 5000, hostName: nil, addresses: nil)
    discoverer.netServiceBrowser(NetServiceBrowser(), didFind: service, moreComing: false)
    discoverer.netServiceDidResolveAddress(service)

    let result = await task.value
    #expect(result == nil)
}

@MainActor
@Test func pairingMDNSDiscovererHandlesUnparseableAddressRecordPayloadAsTimeout() async {
    let discoverer = PairingMDNSDiscoverer()
    let task = Task { await discoverer.discover(serviceName: "droidscout-unparseable-address", timeout: 0.08) }
    try? await Task.sleep(for: .milliseconds(5))

    let service = FakeNetService(name: "droidscout-unparseable-address", port: 5001, hostName: nil, addresses: [Data([0, 1, 2, 3])])
    discoverer.netServiceBrowser(NetServiceBrowser(), didFind: service, moreComing: false)
    discoverer.netServiceDidResolveAddress(service)

    let result = await task.value
    #expect(result == nil)
}

@MainActor
@Test func pairingMDNSDiscovererIgnoresUnmatchedServiceAndTimesOut() async {
    let discoverer = PairingMDNSDiscoverer()
    let timeout: TimeInterval = 0.05
    let task = Task {
        await discoverer.discover(serviceName: "droidscout-match-missing", timeout: timeout)
    }
    let unmatched = FakeNetService(name: "other-service", port: 1111)
    try? await Task.sleep(for: .milliseconds(5))
    discoverer.netServiceBrowser(NetServiceBrowser(), didFind: unmatched, moreComing: false)
    discoverer.netServiceBrowser(NetServiceBrowser(), didRemove: unmatched, moreComing: false)
    discoverer.netServiceDidResolveAddress(unmatched)
    discoverer.netService(unmatched, didNotResolve: [:])

    let result = await task.value
    #expect(result == nil)
}

@Test func localStoreSaveFailurePathDoesNotCrash() throws {
    let temp = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(temp) }

    let conflictingPath = temp.appendingPathComponent("blocked-store")
    try TestSupport.touch(conflictingPath)

    let store = LocalStore(fileManager: .default, supportURL: conflictingPath, logsURL: conflictingPath)
    store.saveSettings(AppSettings.defaults)
    store.saveActivities([])
    store.saveArtifacts([])
    store.saveDeviceNames([:])

    let loadedSettings = store.loadSettings()
    #expect(loadedSettings == .defaults)
}
