# Testing and Coverage

Run the behavior suite and deterministic coverage gate with:

```sh
scripts/test-coverage.sh
```

Run the opt-in real-device integration suite and raw SwiftPM coverage report with:

```sh
scripts/test-real-device-coverage.sh <device-serial>
```

Run the merged raw SwiftPM report for package-testable app library code, including the isolated macOS UI integration pass, with:

```sh
scripts/test-swiftpm-raw-coverage.sh
```

Pass a threshold to make that raw report fail under the requested target:

```sh
scripts/test-swiftpm-raw-coverage.sh 98
```

The real-device script requires an online, authorized physical Android device. If exactly one physical device is connected, the serial argument can be omitted. If multiple physical devices are connected, pass the serial explicitly or set `DROID_SCOUT_TEST_DEVICE_SERIAL`. Set `DROID_SCOUT_TEST_ADB_PATH` to use a specific `adb` binary.

The real-device tests exercise the app against actual `adb` behavior: device listing and hydration, package state polling for the built-in `android` package, model refresh through `DeviceTracker`, and starting/stopping an ADB-backed logcat session. They do not install, uninstall, reboot, clear logcat, or modify app data on the device.

The macOS UI integration pass is opt-in because AppKit drawing is not safe to run concurrently with the async service tests inside SwiftPM's shared test-helper process. The raw coverage script runs it in a separate SwiftPM process and merges the coverage profiles. The UI tests build every settings tab, render the install-progress and popover surfaces through `NSHostingView`, exercise the custom AppKit menu rows, and check the rendered bitmap is non-trivial.

The gate enforces at least 98% line coverage on deterministic logic that can be exercised honestly in unit/integration tests:

- data models and value derivations
- local persistence and diagnostic redaction
- APK metadata parsing
- process execution
- Gradle artifact indexing
- package dumpsys parsing and deploy correlation

The gate excludes the live macOS boundary files:

- `PopoverView.swift` and `SettingsView.swift`: SwiftUI/AppKit rendering and menu interactions need a running macOS UI session for meaningful coverage.
- `StatusBarController.swift` and `main.swift`: status bar lifecycle, popover presentation, app delegate startup, and termination require the real app process.
- `DroidScoutModel.swift`, `ActionServices.swift`, and `ADBServices.swift`: these are partially covered by tests, but also contain file panels, pasteboard, notifications, `NSWorkspace`, Terminal launching, long-running `adb track-devices`, emulator launching, and background polling. Forcing those branches in unit tests would require either controlling live system apps/devices or replacing the behavior with mocks.

The executable entry point and status-bar controller live in the `DroidScoutApp` executable target. SwiftPM compiles that target during `swift test`, but it is not linked into the test bundle, so it is not part of the `llvm-cov` report for `DroidScoutPackageTests`. This keeps `NSApplication.run()`, menu-bar popover presentation, and real AppKit window lifecycle out of the package-test coverage denominator.

As of the current test suite, the deterministic gate reports 99%+ line coverage for the core logic set. The merged raw SwiftPM report for all package-testable library code is 98.04%.

The remaining raw gap is dominated by user-action closures and app-hosted lifecycle code that is not meaningful to force through package tests: real status-bar lifecycle, real window activation, actual Finder/Terminal/GitHub presentation, notification authorization/delivery, and AppKit popup positioning. Those live macOS side effects are injected by the `DroidScoutApp` executable target; the package tests cover the deterministic model behavior, rendered SwiftUI/AppKit surfaces, menu construction, and injected action boundaries.
