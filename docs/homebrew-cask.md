# Homebrew Cask Release

Droid Scout is distributed as a Homebrew cask because it installs a prebuilt macOS `.app` bundle.

The cask intentionally does not depend on `android-platform-tools`. Droid Scout can use ADB from a custom path, Android SDK environment variables, common SDK locations, or `PATH`.

## Release artifact

Prepare a release locally with:

```sh
scripts/prepare-release.sh <version>
```

That command updates `packaging/Info.plist`, refreshes the README coverage badge,
runs the CI-safe test set, builds the release zip, writes the checksum, and
renders `.build/release/droid-scout.rb`.

To also commit, tag, and push the tag that starts the GitHub release workflow:

```sh
scripts/prepare-release.sh <version> --commit --tag --push
```

Create only the cask artifact from a clean release commit with:

```sh
scripts/package-cask-release.sh release
```

The script builds the app bundle with `scripts/build-app.sh release`, writes `.build/release/DroidScout-<version>.zip`, and writes `.build/release/DroidScout-<version>.zip.sha256`.

For a Gatekeeper-friendly public release, sign and notarize the app before publishing. The package script supports these environment variables:

```sh
DROID_SCOUT_CODESIGN_IDENTITY="Developer ID Application: Example (TEAMID)"
DROID_SCOUT_NOTARY_KEYCHAIN_PROFILE="notary-profile"
```

Or use App Store Connect API key notarization:

```sh
DROID_SCOUT_CODESIGN_IDENTITY="Developer ID Application: Example (TEAMID)"
DROID_SCOUT_NOTARY_KEY_PATH="/path/to/AuthKey_KEYID.p8"
DROID_SCOUT_NOTARY_KEY_ID="KEYID"
DROID_SCOUT_NOTARY_ISSUER_ID="issuer-uuid"
```

## Render the cask

After packaging, render the Homebrew cask file:

```sh
scripts/render-homebrew-cask.sh
```

The rendered file is written to `.build/release/droid-scout.rb` and uses the checksum from the release zip.

## Publish from GitHub Actions

Pushing a tag such as `v0.1.0` runs `.github/workflows/release.yml`. The workflow builds the zip, checksum, and rendered cask, then uploads all three to the GitHub release.

To sign and notarize in GitHub Actions, add these repository secrets:

```text
DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64
DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD
DEVELOPER_ID_APPLICATION_IDENTITY
DEVELOPER_ID_KEYCHAIN_PASSWORD
APP_STORE_CONNECT_API_KEY_BASE64
APP_STORE_CONNECT_API_KEY_ID
APP_STORE_CONNECT_ISSUER_ID
```

To automatically open a pull request against a Homebrew tap, configure:

```text
Repository variable:
HOMEBREW_TAP_REPOSITORY=samkit/homebrew-tap

Repository secret:
HOMEBREW_TAP_TOKEN=<GitHub token with write access to the tap repository>
```

When those are present, the release workflow copies the generated cask to
`Casks/droid-scout.rb` in the tap repository, pushes a release branch, and opens
a pull request.

The generated cask can also be used as the source for a pull request to
`Homebrew/homebrew-cask` once the app meets Homebrew's acceptance requirements.
