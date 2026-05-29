#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="${ROOT_DIR}/packaging/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${INFO_PLIST}")"
BUILD_DIR="${ROOT_DIR}/.build/${CONFIGURATION}"
APP_PATH="${BUILD_DIR}/Droid Scout.app"
ZIP_NAME="DroidScout-${VERSION}.zip"
ZIP_PATH="${BUILD_DIR}/${ZIP_NAME}"
SHA_PATH="${ZIP_PATH}.sha256"

"${ROOT_DIR}/scripts/build-app.sh" "${CONFIGURATION}" >/dev/null

if [[ -n "${DROID_SCOUT_CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "${DROID_SCOUT_CODESIGN_IDENTITY}" "${APP_PATH}"
  codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
fi

zip_app() {
  rm -f "${ZIP_PATH}"
  (
    cd "${BUILD_DIR}"
    ditto -c -k --sequesterRsrc --keepParent "Droid Scout.app" "${ZIP_NAME}"
  )
}

notary_args=()
if [[ -n "${DROID_SCOUT_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  notary_args=(--keychain-profile "${DROID_SCOUT_NOTARY_KEYCHAIN_PROFILE}")
elif [[ -n "${DROID_SCOUT_NOTARY_KEY_ID:-}" && -n "${DROID_SCOUT_NOTARY_ISSUER_ID:-}" && -n "${DROID_SCOUT_NOTARY_KEY_PATH:-}" ]]; then
  notary_args=(
    --key "${DROID_SCOUT_NOTARY_KEY_PATH}"
    --key-id "${DROID_SCOUT_NOTARY_KEY_ID}"
    --issuer "${DROID_SCOUT_NOTARY_ISSUER_ID}"
  )
fi

zip_app

if [[ ${#notary_args[@]} -gt 0 ]]; then
  if [[ -z "${DROID_SCOUT_CODESIGN_IDENTITY:-}" ]]; then
    echo "Notarization requires DROID_SCOUT_CODESIGN_IDENTITY." >&2
    exit 1
  fi
  xcrun notarytool submit "${ZIP_PATH}" --wait "${notary_args[@]}"
  xcrun stapler staple "${APP_PATH}"
  zip_app
fi

rm -f "${SHA_PATH}"
shasum -a 256 "${ZIP_PATH}" | tee "${SHA_PATH}"

echo "Archive: ${ZIP_PATH}"
echo "SHA256:  ${SHA_PATH}"
