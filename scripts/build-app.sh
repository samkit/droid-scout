#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build/${CONFIGURATION}"
APP_PATH="${BUILD_DIR}/Droid Scout.app"

cd "${ROOT_DIR}"
swift build -c "${CONFIGURATION}"

rm -rf "${APP_PATH}"
mkdir -p "${APP_PATH}/Contents/MacOS" "${APP_PATH}/Contents/Resources"
cp "${BUILD_DIR}/DroidScout" "${APP_PATH}/Contents/MacOS/DroidScout"
cp "${ROOT_DIR}/packaging/Info.plist" "${APP_PATH}/Contents/Info.plist"
cp -R "${ROOT_DIR}/packaging/Resources/." "${APP_PATH}/Contents/Resources/"
touch "${APP_PATH}"

echo "${APP_PATH}"
