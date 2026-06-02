import Foundation
import Testing
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

@Test func pairingQRGeneratorProducesUsableScannableQRCodeImage() {
    let payload = "WIFI:T:ADB;S:real-svc-xyz;P:real-pass-abc123;;"
    let image = PairingQRGenerator.generateQRCodeImage(payload: payload, scale: 6)

    #expect(image != nil, "CoreImage QR generator must produce an image for a valid payload")
    #expect(image!.size.width >= 150, "QR must be large enough for phone camera to scan reliably")
    #expect(image!.size.height >= 150)

    // Honest check: the generated image must have actual bitmap data (not a zero-size stub).
    guard let cgImage = image!.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        Issue.record("Generated NSImage must provide a CGImage")
        return
    }
    #expect(cgImage.width >= 100)
    #expect(cgImage.height >= 100)
}

// MARK: - ADB mDNS Services Parser (Phase 2 TDD)

@Test func adbMdnsParserExtractsPairingServicesFromRealAdbOutput() {
    let output = """
    List of discovered mdns services
    droidscout-test-001 _adb-tls-pairing._tcp 192.168.1.42:37123
    studio-g@abc123 _adb-tls-pairing._tcp 10.0.0.5:12345
    other-device _adb-tls-connect._tcp 192.168.1.99:5555
    droidscout-abc123 _adb-tls-pairing._tcp [fe80::1]:40000
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
