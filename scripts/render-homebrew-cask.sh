#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="${ROOT_DIR}/packaging/Info.plist"
TEMPLATE_PATH="${ROOT_DIR}/packaging/homebrew/droid-scout.rb.template"
OUTPUT_PATH="${1:-${ROOT_DIR}/.build/release/droid-scout.rb}"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${INFO_PLIST}")"
SHA_PATH="${ROOT_DIR}/.build/release/DroidScout-${VERSION}.zip.sha256"

if [[ -z "${DROID_SCOUT_RELEASE_SHA256:-}" ]]; then
  if [[ ! -f "${SHA_PATH}" ]]; then
    echo "Missing ${SHA_PATH}. Run scripts/package-cask-release.sh release first." >&2
    exit 1
  fi
  DROID_SCOUT_RELEASE_SHA256="$(awk '{print $1}' "${SHA_PATH}")"
fi

mkdir -p "$(dirname "${OUTPUT_PATH}")"
sed \
  -e "s/__VERSION__/${VERSION}/g" \
  -e "s/__SHA256__/${DROID_SCOUT_RELEASE_SHA256}/g" \
  "${TEMPLATE_PATH}" > "${OUTPUT_PATH}"

echo "${OUTPUT_PATH}"
