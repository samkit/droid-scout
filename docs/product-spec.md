# Droid Scout Product Spec

Status: agreed v1 scope

Droid Scout is a native macOS menu-bar utility for Android developers. It uses the user's installed `adb` to track connected Android devices, show useful device identity, run common install/log workflows, and detect recent APK deployments from configured Android projects.

The product should feel like a focused macOS utility, not a replacement for Android Studio, Terminal, or a full ADB desktop client.

## Product Boundary

Droid Scout is a menu-bar device/session utility.

It should make daily Android development tasks faster:

- See connected Android devices without opening Terminal.
- Understand device identity and authorization state quickly.
- Install or reinstall APKs to one or more selected devices.
- Detect external APK deploys from Android Studio or Gradle for configured projects.
- Start logcat streams without building an in-app text editor.
- Notify about device, install, deploy, and update events without becoming noisy.

Droid Scout should not become a broad ADB control panel in v1.

## Target Platform

- Native macOS app.
- Swift and SwiftUI for app structure and UI.
- AppKit where needed for `NSStatusItem`, file pickers, notifications, Terminal launching, and other macOS integration points.
- Minimum target: macOS 13.
- No Electron.

The UI should follow modern macOS design conventions: native materials, spacing, typography, sheets, settings surfaces, accessibility labels, keyboard navigation, and VoiceOver-friendly controls.

## Primary UI

The primary app surface is a menu-bar popover opened from a status item near the system clock.

Droid Scout should not have a general main window in v1. Focused secondary windows or sheets are allowed for settings, install status, and other task-specific flows.

### Menu-Bar Icon

The status item should communicate useful state without requiring the user to open the popover:

- No devices: dim phone/Android-style icon.
- One or more online devices: normal icon with count.
- Unauthorized or offline device present: warning variant.
- ADB missing or broken: error variant.

The menu-bar item should not show device names by default.

### Popover Layout

The v1 popover should be compact and ordered as follows:

1. Header row
   - App name/status.
   - Refresh button.
   - Settings button.
2. ADB status
   - Hidden when healthy.
   - Shows setup/error banner when ADB is missing, unauthorized devices are present, or the watcher fails.
3. Devices
   - Compact rows with friendly name, shortened serial, state, Android version/API, and transport hint when available.
   - Selection checkboxes for multi-device actions.
   - Per-device overflow menu for scoped actions.
4. Primary actions
   - Install APK...
   - Reinstall Recent...
   - Start Logs
   - Clear Logcat Buffer
5. Recent Activity
   - Last few installs and detected external deploys.
   - Per-device result summary.
6. Footer
   - Check Updates
   - Reveal Logs
   - Quit

## Device Tracking

Droid Scout should use `adb track-devices` as the primary source of connected-device state.

Device tracking responsibilities:

- Locate and validate `adb`.
- Start `adb track-devices`.
- Parse device serial and state.
- Fetch useful device details when devices appear or state changes.
- Restart the app-owned tracking process if it exits.
- Periodically verify the watcher is healthy.
- Provide manual repair actions for broader ADB server issues.

The app should not automatically run disruptive commands such as `adb kill-server` unless the user explicitly chooses a repair action.

### Device Identity

The device list should show only fields that help developers choose the right target quickly:

- Friendly device name, such as `Pixel 8 Pro`.
- Android version and API level.
- Serial, shortened by default and copyable in full.
- State: `online`, `unauthorized`, or `offline`.
- Transport hint, such as USB or Wi-Fi, when cheaply detectable.

Deeper fields such as ABI, screen size, battery, build fingerprint, root state, and carrier are not part of the main v1 device list.

## ADB Setup

Droid Scout should use the user's installed Android SDK platform-tools. It should not bundle ADB in v1.

Discovery order:

1. Explicit path from app settings.
2. `$ANDROID_HOME/platform-tools/adb`.
3. `$ANDROID_SDK_ROOT/platform-tools/adb`.
4. Common macOS SDK paths, including `~/Library/Android/sdk/platform-tools/adb`.
5. `PATH`.

If ADB is not found, Droid Scout should show a setup state with:

- Choose ADB...
- Retry Detection
- Copyable install hint: `brew install android-platform-tools`

The manually configured ADB path should override automatic detection.

## V1 Actions

The v1 quick actions are:

- Copy Serial
- Open Log Stream
- Clear Logcat Buffer
- Install APK...
- Reinstall Recent APK
- Open Shell

Other ADB actions are deferred to the v2 backlog.

## APK Install

Droid Scout must support installing one APK to one or more selected devices in v1.

Install behavior:

- Install can start from a specific device row or from a global action.
- Device-row install preselects that device.
- Global install opens a device picker.
- Users may select one or more online devices.
- The app runs one ADB install job per selected device.
- Per-device status is tracked independently.
- A final summary notification can report aggregate result, such as `Installed on 2 of 3 devices`.

Supported statuses:

- Queued
- Installing
- Success
- Failed with stderr
- Skipped because unauthorized/offline

Installs should run concurrently with a small limit, initially 3.

Supported install types:

- Single APK: `adb install -r <apk>`
- Split APK group: `adb install-multiple -r <base.apk> <split-apks...>`
- AAB: visible as an artifact when discovered, but not directly installable in v1

## Recent APK Reinstall

Recent reinstall should be package-aware and device-aware.

Droid Scout should remember recent APKs and split APK groups from installs it performed and external deploys it detected:

- Artifact path or split group paths.
- Package name.
- Version name and version code when available.
- Last installed or detected timestamp.
- Devices installed to.
- Per-device last result.
- Source: Droid Scout install or detected external deploy.
- Confidence for detected external deploys.

Reinstall Recent should let the user pick from recent artifacts and select target devices. It should default to devices where that artifact was previously installed.

## External Deploy Tracking

Tracking APKs installed by other tools is a primary v1 requirement.

The app must support detecting APK deployments made outside Droid Scout, especially from Android Studio and Gradle, for configured Android project folders.

### Project Awareness

V1 requires users to add Android project folders to watch. Without configured project folders, Droid Scout may know that a package changed on a device, but it usually cannot know which local APK file should be redeployed.

Project watcher responsibilities:

- Store watched Android project roots.
- Index known package IDs and variants from those roots.
- Scan standard Gradle and Android Studio build outputs.
- Track recent build artifact changes.

Supported project artifacts:

- APKs under `**/build/outputs/apk/**/*.apk`.
- APK metadata from `output-metadata.json`.
- Split APK sets under standard Gradle APK output directories.
- AAB files under `**/build/outputs/bundle/**/*.aab` for display only.

Custom artifact directories are deferred to v2.

### Device Package State

Droid Scout should track package state only for package IDs that map to configured project roots by default.

It should not show a broad inventory of all installed packages in v1.

Package-state polling:

- Refresh immediately when a device connects.
- Poll known package IDs every 10-15 seconds while devices are online.
- Run a short burst refresh after local APK artifact changes.
- Provide a manual refresh action.

Implementation may use scoped ADB commands such as:

- `adb -s <serial> shell dumpsys package <packageId>`
- `adb -s <serial> shell cmd package dump <packageId>`

The app should compare package version and install/update timestamps against previous snapshots.

### Deploy Correlation

When a known package changes on a device, Droid Scout should try to correlate that change to a local artifact from configured projects.

Matching signals:

- Package name from APK manifest or metadata.
- Version code/version name.
- Artifact modified time near device update time.
- Gradle output metadata.
- Variant/build type when available.

Detected external deploy records should include:

- Device.
- Package.
- Local artifact path or split APK group when matched.
- Source: external.
- Confidence: high, medium, or low.
- Evidence summary useful for debugging.

The app should be honest about uncertainty:

- High/medium confidence: offer one-click redeploy.
- Low confidence: ask the user to choose from candidates.
- No match: record the package change in activity only if useful, without pretending a redeployable artifact exists.

## Logs

Droid Scout should not implement an in-app text editor or log viewer in v1.

Open Log Stream behavior:

- Starts `adb -s <serial> logcat`.
- Writes output to a local log file.
- Opens the stream using the configured external target.
- Tracks active sessions with stop, reveal file, and copy path actions.

Default log target:

- Terminal tailing the generated log file.

Optional log targets:

- VS Code.
- Zed.
- Default macOS app.

Log files should live under:

- `~/Library/Logs/Droid Scout/`

The app should support revealing the logs folder and configuring retention.

### Clear Logs

Clear Logs in the device action surface means clearing the device logcat buffer:

- `adb -s <serial> logcat -c`

Deleting local log files is a separate retention/maintenance concern.

## Settings

V1 settings should use a modern native macOS settings surface with these sections:

### ADB

- Detected ADB path.
- Choose custom path.
- Retry detection.
- Homebrew install hint.

### Projects

- Add/remove watched Android project folders.
- Show detected package IDs and variants.

### Logs

- Default log target: Terminal, VS Code, Zed, or default app.
- Log retention period.
- Reveal logs folder.

### Updates

- Check for updates.
- Background update checks toggle.

### Advanced

- Package polling interval.
- External deploy confidence threshold.
- Diagnostics export.

Avoid putting many preferences directly in the popover.

## Notifications

V1 should notify only for events that matter.

Notification events:

- Device connected.
- Device disconnected unexpectedly.
- Device unauthorized.
- Install/reinstall completed with summary.
- Install/reinstall failed.
- External deploy detected with high confidence.
- Update available.

Do not notify for every package poll, routine refresh, or log session start/stop.

### Notification Modes

Droid Scout should support three notification modes:

- Full
  - Device connect/disconnect.
  - Unauthorized device.
  - Install result.
  - External deploy detected.
  - Update available.
- Reduced
  - Suppress routine device connect/disconnect notifications.
  - Batch external deploy detections into a short digest.
  - Still notify unauthorized devices, install failures, and update availability.
  - Show install success in app history, not as a macOS notification.
- Off
  - No macOS notifications.
  - Events remain visible in the app.

The app should avoid repeated notification spam for the same device/package state.

## Distribution And Updates

Distribution model:

- GitHub Releases are the source of truth.
- Release artifact is a signed and notarized macOS app, likely packaged as `.dmg` or `.zip`.
- Homebrew Cask provides installation via Homebrew.
- Sparkle provides native update checks and notifications.

V1 should include:

- Check for Updates...
- Background update checks toggle.
- Update available notification.

Homebrew users can still upgrade via `brew upgrade`, but Droid Scout should support native update notifications through Sparkle.

## Privacy

Droid Scout should have no telemetry in v1.

Privacy stance:

- No analytics.
- No crash reporting by default.
- No cloud account.
- No synced storage.
- No remote calls except update checks to GitHub/Sparkle appcast.
- Diagnostics export is generated only on demand.
- Diagnostics should redact device serials by default.

The README should document what is stored locally and where before public release.

## Local Storage

Use simple local storage in v1.

Storage locations:

- Preferences: `UserDefaults`.
- Recent install/deploy history: JSON under `~/Library/Application Support/Droid Scout/`.
- Logs: `~/Library/Logs/Droid Scout/`.
- Diagnostics: generated only on demand.

Persisted state:

- Custom ADB path.
- Watched project folders.
- Notification mode.
- Log target and retention.
- Recent APK artifacts and split groups.
- Per-device install/deploy history.
- Last known non-sensitive device display names.

Avoid SQLite/Core Data in v1 unless the event volume or query needs become clearly larger than expected.

## Minimal Architecture

V1 should use small services with clear responsibilities:

- `StatusBarController`
  - Owns menu-bar icon, device count, and warning state.
- `PopoverViewModel`
  - Combines device state, activity state, and available actions.
- `ADBLocator`
  - Finds and validates `adb`.
- `ADBClient`
  - Runs scoped ADB commands and captures output/errors.
- `DeviceTracker`
  - Owns `adb track-devices`.
- `DeviceInfoService`
  - Resolves device model, Android version/API, and transport hint.
- `ProjectRegistry`
  - Stores watched project folders.
- `ArtifactIndexer`
  - Scans Gradle APK/split outputs and reads metadata.
- `PackageStatePoller`
  - Checks known package state on devices.
- `DeployCorrelator`
  - Matches package changes to local artifacts with confidence.
- `InstallCoordinator`
  - Handles single/multi-device installs and per-device statuses.
- `LogSessionManager`
  - Writes logcat streams to files and opens external targets.
- `NotificationManager`
  - Applies Full/Reduced/Off notification behavior.
- `UpdateService`
  - Wraps Sparkle.
- `LocalStore`
  - Handles JSON and `UserDefaults` persistence.

This structure avoids one large ADB manager while keeping the implementation understandable.

## V1 Success Criteria

V1 is successful if:

- Connected Android devices are detected reliably within a few seconds.
- ADB setup and device authorization problems are clear and actionable.
- One APK can be installed to multiple selected devices with per-device feedback.
- Android Studio/Gradle external deploys are detected for configured projects often enough to be useful.
- Detected artifacts can be redeployed without making users search build folders.
- Live logs open in Terminal or a chosen external editor without Droid Scout becoming an editor.
- The app ships as a signed/notarized app through GitHub Releases and Homebrew Cask.
- Users receive upgrade notifications.
- The app feels like a polished native macOS menu-bar utility.

## V1 Non-Goals

These are intentionally out of scope for v1:

- Full ADB desktop client.
- General Android package inventory.
- In-app text editor or log viewer.
- In-app code editor integrations beyond opening log files.
- Replacing Android Studio, Gradle, or Terminal.
- Automatically killing/restarting the global ADB server without user action.
- Bundling ADB.
- Telemetry or default crash reporting.

## V2 Backlog

Potential future enhancements:

- Screenshots.
- Screen recording.
- `scrcpy` launch.
- File browser / pull-push files.
- App data clear.
- Uninstall app.
- Reboot and restart-ADB-server helpers.
- Port forwarding.
- Custom artifact directories.
- AAB install via bundletool.
- Deeper Android Studio integration.
- Gradle task execution.
- Smarter package/process log filtering.
- Per-event notification preferences.
- Broad package inventory view.
- Install to saved device groups.
- Richer diagnostics.
- Optional crash reporting.
- Stable/beta/nightly update channels.
