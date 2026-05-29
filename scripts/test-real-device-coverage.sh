#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ADB_PATH="${DROID_SCOUT_TEST_ADB_PATH:-}"
REQUESTED_SERIAL="${1:-${DROID_SCOUT_TEST_DEVICE_SERIAL:-}}"
TEST_BINARY="${ROOT_DIR}/.build/arm64-apple-macosx/debug/DroidScoutPackageTests.xctest/Contents/MacOS/DroidScoutPackageTests"
PROFILE="${ROOT_DIR}/.build/arm64-apple-macosx/debug/codecov/default.profdata"

cd "${ROOT_DIR}"

if [[ -z "${ADB_PATH}" ]]; then
    if ! ADB_PATH="$(command -v adb)"; then
        echo "adb was not found. Set DROID_SCOUT_TEST_ADB_PATH or install Android platform-tools." >&2
        exit 1
    fi
fi

if [[ ! -x "${ADB_PATH}" ]]; then
    echo "ADB path is not executable: ${ADB_PATH}" >&2
    exit 1
fi

PHYSICAL_SERIALS=()
while IFS= read -r serial; do
    PHYSICAL_SERIALS+=("${serial}")
done < <("${ADB_PATH}" devices -l | awk '$2 == "device" && $1 !~ /^emulator-/ { print $1 }')

if [[ -z "${REQUESTED_SERIAL}" ]]; then
    if [[ "${#PHYSICAL_SERIALS[@]}" -eq 0 ]]; then
        echo "No online physical Android device found. Connect and authorize a real device, then rerun." >&2
        "${ADB_PATH}" devices -l >&2
        exit 1
    fi
    if [[ "${#PHYSICAL_SERIALS[@]}" -gt 1 ]]; then
        echo "Multiple online physical devices found. Pass a serial or set DROID_SCOUT_TEST_DEVICE_SERIAL:" >&2
        printf '  %s\n' "${PHYSICAL_SERIALS[@]}" >&2
        exit 1
    fi
    REQUESTED_SERIAL="${PHYSICAL_SERIALS[0]}"
fi

if [[ "$("${ADB_PATH}" -s "${REQUESTED_SERIAL}" get-state 2>/dev/null || true)" != "device" ]]; then
    echo "Selected device is not online or not authorized: ${REQUESTED_SERIAL}" >&2
    "${ADB_PATH}" devices -l >&2
    exit 1
fi

echo "Running real-device integration tests on ${REQUESTED_SERIAL}"
DROID_SCOUT_REAL_DEVICE_TESTS=1 \
DROID_SCOUT_TEST_ADB_PATH="${ADB_PATH}" \
DROID_SCOUT_TEST_DEVICE_SERIAL="${REQUESTED_SERIAL}" \
env DEVELOPER_DIR="${DEVELOPER_DIR}" swift test --disable-sandbox --enable-code-coverage

echo
echo "Raw SwiftPM coverage including app, UI, and OS boundary files:"
xcrun llvm-cov report "${TEST_BINARY}" \
    -instr-profile "${PROFILE}" \
    -ignore-filename-regex='.build|Tests'
