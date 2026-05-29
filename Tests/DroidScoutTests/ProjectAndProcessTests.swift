import Foundation
import Testing
@testable import DroidScout

@Test func processRunnerCapturesOutputExitCodesLaunchFailuresAndTimeouts() async {
    let failed = ProcessRunner.runSync(
        executablePath: "/bin/sh",
        arguments: ["-c", "echo out; echo err >&2; exit 7"],
        timeout: 5
    )
    #expect(failed.stdout == "out\n")
    #expect(failed.stderr == "err\n")
    #expect(failed.exitCode == 7)
    #expect(!failed.succeeded)

    let missing = ProcessRunner.runSync(executablePath: "/path/that/does/not/exist", arguments: [])
    #expect(missing.exitCode == -1)
    #expect(missing.stderr.nilIfBlank != nil)

    let timedOut = await ProcessRunner.run(
        executablePath: "/bin/sh",
        arguments: ["-c", "sleep 2"],
        timeout: 0.1
    )
    #expect(timedOut.exitCode == -9)
    #expect(timedOut.stderr == "Timed out after 0s")

    let invalidUTF8 = ProcessRunner.runSync(
        executablePath: "/usr/bin/python3",
        arguments: ["-c", "import sys; sys.stdout.buffer.write(bytes([0xff])); sys.stderr.buffer.write(bytes([0xfe]))"],
        timeout: 5
    )
    #expect(invalidUTF8.succeeded)
    #expect(invalidUTF8.stdout == "")
    #expect(invalidUTF8.stderr == "")
}

@Test func stringAndURLHelpersHandleWhitespaceShellEscapingAndDecodedPaths() {
    #expect("  value \n".nilIfBlank == "value")
    #expect(" \t\n".nilIfBlank == nil)
    #expect("plain".shellEscaped == "'plain'")
    #expect("it's here".shellEscaped == "'it'\\''s here'")
    #expect(URL(fileURLWithPath: "/tmp/space here").pathString == "/tmp/space here")
}

@Test func artifactIndexerScansGradleOutputsWithRealFilesystemFixtures() async throws {
    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(root) }

    let debugDir = root.appendingPathComponent("app/build/outputs/apk/debug", isDirectory: true)
    let splitOne = debugDir.appendingPathComponent("app-arm64-v8a-debug.apk")
    let splitTwo = debugDir.appendingPathComponent("app-x86-debug.apk")
    try TestSupport.touch(splitOne, modifiedAt: Date(timeIntervalSince1970: 100))
    try TestSupport.touch(splitTwo, modifiedAt: Date(timeIntervalSince1970: 200))
    try TestSupport.write(
        """
        {
          "version": 3,
          "artifactType": "APK",
          "applicationId": "com.example.debug",
          "variantName": "debug",
          "elements": [
            {
              "type": "ONE_OF_MANY",
              "versionCode": 12,
              "versionName": "2.0",
              "outputFile": "app-arm64-v8a-debug.apk"
            }
          ]
        }
        """,
        to: debugDir.appendingPathComponent("output-metadata.json")
    )

    let releaseBundle = root.appendingPathComponent("app/build/outputs/bundle/release/app-release.aab")
    try TestSupport.touch(releaseBundle, modifiedAt: Date(timeIntervalSince1970: 300))

    try TestSupport.touch(root.appendingPathComponent("app/build/intermediates/apk/debug/intermediate.apk"))
    try TestSupport.touch(root.appendingPathComponent(".gradle/build/outputs/apk/debug/ignored.apk"))

    let records = await ArtifactIndexer().indexProjects(paths: [root.pathString])
    #expect(records.count == 2)
    #expect(records.map(\.kind).contains(.splitAPK))
    #expect(records.map(\.kind).contains(.aab))

    guard let split = records.first(where: { $0.kind == .splitAPK }) else {
        Issue.record("Expected split APK record")
        return
    }
    #expect(split.paths.map { URL(fileURLWithPath: $0).lastPathComponent } == ["app-arm64-v8a-debug.apk", "app-x86-debug.apk"])
    #expect(split.packageName == "com.example.debug")
    #expect(split.versionName == "2.0")
    #expect(split.versionCode == "12")
    #expect(split.variant == "debug")
    #expect(split.source == .indexedProject)
    #expect(split.lastSeen == Date(timeIntervalSince1970: 200))
    #expect(split.evidence?.contains("/build/outputs/apk/debug") == true)

    guard let aab = records.first(where: { $0.kind == .aab }) else {
        Issue.record("Expected AAB record")
        return
    }
    #expect(aab.paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().pathString } == [releaseBundle.resolvingSymlinksInPath().pathString])
    #expect(aab.variant == "release")
    #expect(aab.packageName == nil)
    #expect(aab.versionSummary == "release")
    #expect(!aab.isReinstallable)
}

@Test func artifactIndexerHandlesMissingRootsInvalidMetadataAndVariantlessAPKDirectories() async throws {
    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(root) }

    let apk = root.appendingPathComponent("module/build/outputs/apk/app.apk")
    try TestSupport.touch(apk, modifiedAt: Date(timeIntervalSince1970: 500))
    try TestSupport.write("{not-json", to: apk.deletingLastPathComponent().appendingPathComponent("output-metadata.json"))

    let records = await ArtifactIndexer().indexProjects(paths: [
        root.appendingPathComponent("missing").pathString,
        root.pathString
    ])

    #expect(records.count == 1)
    #expect(records[0].kind == .apk)
    #expect(records[0].paths.map { URL(fileURLWithPath: $0).lastPathComponent } == ["app.apk"])
    #expect(records[0].variant == nil)
    #expect(records[0].packageName == nil)
    #expect(records[0].lastSeen == Date(timeIntervalSince1970: 500))
}

@Test func packageStatePollerUsesRealADBAndSkipsOfflineDevices() async throws {
    let temp = try TestSupport.temporaryDirectory()
    defer { TestSupport.cleanup(temp) }
    let adb = temp.appendingPathComponent("adb")
    try TestSupport.executableScript(adb, body: """
    if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "dumpsys" ]; then
      if [ "$6" = "com.present" ]; then
        echo "Package [com.present] (abc):"
        echo "  versionName="
        echo "  firstInstallTime=2026-05-20 09:00:00"
        echo "  lastUpdateTime=2026-05-21 10:00:00"
        exit 0
      fi
      echo "not found"
      exit 0
    fi
    exit 64
    """)

    let poller = PackageStatePoller(adbClient: ADBClient(adbPath: adb.pathString))
    let empty = await poller.snapshots(for: [], devices: [TestSupport.device(serial: "USB1")])
    #expect(empty.isEmpty)

    let snapshots = await poller.snapshots(
        for: ["com.present", "com.missing"],
        devices: [
            TestSupport.device(serial: "USB1", state: .online),
            TestSupport.device(serial: "USB2", state: .offline)
        ]
    )

    #expect(snapshots.count == 1)
    #expect(snapshots[0].deviceSerial == "USB1")
    #expect(snapshots[0].packageName == "com.present")
    #expect(snapshots[0].versionName == nil)
    #expect(snapshots[0].versionCode == nil)
    #expect(snapshots[0].firstInstallTime == "2026-05-20 09:00:00")
    #expect(snapshots[0].lastUpdateTime == "2026-05-21 10:00:00")
}

@Test func packageDumpsysParserExtractsInstalledPackageState() {
    let observedAt = Date(timeIntervalSince1970: 123)
    let stdout = """
    Packages:
      Package [com.example.app] (123abc):
        userId=10234
        versionCode=42 minSdk=23 targetSdk=35
        versionName=2.4.1
        firstInstallTime=2026-05-27 10:00:00
        lastUpdateTime=2026-05-28 11:00:00
    """

    guard let snapshot = PackageDumpsysParser.parse(
        packageID: "com.example.app",
        deviceSerial: "USB1",
        stdout: stdout,
        observedAt: observedAt
    ) else {
        Issue.record("Expected dumpsys package output to parse")
        return
    }

    #expect(snapshot.deviceSerial == "USB1")
    #expect(snapshot.packageName == "com.example.app")
    #expect(snapshot.versionCode == "42")
    #expect(snapshot.versionName == "2.4.1")
    #expect(snapshot.firstInstallTime == "2026-05-27 10:00:00")
    #expect(snapshot.lastUpdateTime == "2026-05-28 11:00:00")
    #expect(snapshot.observedAt == observedAt)
    #expect(PackageDumpsysParser.parse(packageID: "missing", deviceSerial: "USB1", stdout: "No packages") == nil)
}

@Test func deployCorrelatorUsesExactVersionMetadataThenNewestPackageMatch() {
    let exact = TestSupport.artifact(
        paths: ["/tmp/exact.apk"],
        packageName: "com.example.app",
        versionName: "2.0",
        versionCode: "20",
        lastSeen: Date(timeIntervalSince1970: 10)
    )
    let newest = TestSupport.artifact(
        paths: ["/tmp/newest.apk"],
        packageName: "com.example.app",
        versionName: "3.0",
        versionCode: "30",
        lastSeen: Date(timeIntervalSince1970: 20)
    )
    let ignoredBundle = TestSupport.artifact(
        paths: ["/tmp/app.aab"],
        packageName: "com.example.app",
        versionName: "2.0",
        versionCode: "20",
        kind: .aab,
        lastSeen: Date(timeIntervalSince1970: 30)
    )
    let snapshot = PackageSnapshot(
        deviceSerial: "USB1",
        packageName: "com.example.app",
        versionName: "2.0",
        versionCode: "20",
        firstInstallTime: nil,
        lastUpdateTime: nil,
        observedAt: Date()
    )

    let correlator = DeployCorrelator()
    let high = correlator.correlate(snapshot: snapshot, artifacts: [ignoredBundle, newest, exact])
    #expect(high.confidence == .high)
    #expect(high.artifact?.paths == exact.paths)
    #expect(high.artifact?.source == .external)
    #expect(high.evidence.contains("version metadata"))

    let differentVersion = PackageSnapshot(
        deviceSerial: "USB1",
        packageName: "com.example.app",
        versionName: "9.0",
        versionCode: "90",
        firstInstallTime: nil,
        lastUpdateTime: nil,
        observedAt: Date()
    )
    let medium = correlator.correlate(snapshot: differentVersion, artifacts: [exact, newest])
    #expect(medium.confidence == .medium)
    #expect(medium.artifact?.paths == newest.paths)
    #expect(medium.evidence.contains("application ID"))

    let low = correlator.correlate(snapshot: differentVersion, artifacts: [ignoredBundle])
    #expect(low.confidence == .low)
    #expect(low.artifact == nil)
    #expect(low.evidence.contains("no matching local APK"))
}
