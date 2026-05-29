#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
THRESHOLD="${1:-}"

cd "${ROOT_DIR}"
mkdir -p .build
BASE_DIR="$(mktemp -d "${ROOT_DIR}/.build/raw-base.XXXXXX")"
MODEL_DIR="$(mktemp -d "${ROOT_DIR}/.build/raw-model.XXXXXX")"
UI_DIR="$(mktemp -d "${ROOT_DIR}/.build/raw-ui.XXXXXX")"

find_codecov_dir() {
    find "$1" -type d -path '*/debug/codecov' -print -quit
}

find_test_binary() {
    find "$1" -path '*/DroidScoutPackageTests.xctest/Contents/MacOS/DroidScoutPackageTests' -type f -print -quit
}

echo "Running default SwiftPM coverage pass..."
env DEVELOPER_DIR="${DEVELOPER_DIR}" swift test \
    --scratch-path "${BASE_DIR}" \
    --disable-sandbox \
    --no-parallel \
    --enable-code-coverage

echo
echo "Running isolated model boundary coverage pass..."
DROID_SCOUT_MODEL_BOUNDARY_TESTS=1 \
env DEVELOPER_DIR="${DEVELOPER_DIR}" swift test \
    --scratch-path "${MODEL_DIR}" \
    --disable-sandbox \
    --no-parallel \
    --enable-code-coverage \
    --filter 'modelPanelHelpersLogsPackageChangesAndInjectedAppActionsUseRealBoundaries|modelInstallAndDeviceBranchesCoverFailuresAndEmulatorStart|defaultSystemActionsAndModelBoundariesAreInertButCallable'

echo
echo "Running isolated macOS UI coverage pass..."
DROID_SCOUT_UI_TESTS=1 \
env DEVELOPER_DIR="${DEVELOPER_DIR}" swift test \
    --scratch-path "${UI_DIR}" \
    --disable-sandbox \
    --no-parallel \
    --enable-code-coverage \
    --filter 'settingsAndInstallProgressRenderEveryPaneInMacWindows|popoverNativeControlsHandleAppKitEventsAndMenus|renderedMacControlsInvokeRealModelActionsWithInjectedSystemBoundaries'

BASE_CODECOV="$(find_codecov_dir "${BASE_DIR}")"
MODEL_CODECOV="$(find_codecov_dir "${MODEL_DIR}")"
UI_CODECOV="$(find_codecov_dir "${UI_DIR}")"
TEST_BINARY="$(find_test_binary "${BASE_DIR}")"
MERGED_PROFILE="${BASE_CODECOV}/merged.profdata"

if [[ -z "${BASE_CODECOV}" || -z "${MODEL_CODECOV}" || -z "${UI_CODECOV}" || -z "${TEST_BINARY}" ]]; then
    echo "Could not locate SwiftPM coverage outputs." >&2
    exit 1
fi

xcrun llvm-profdata merge -sparse "${BASE_CODECOV}"/*.profraw "${MODEL_CODECOV}"/*.profraw "${UI_CODECOV}"/*.profraw -o "${MERGED_PROFILE}"

echo
echo "Merged raw SwiftPM coverage for package-testable app library code:"
REPORT="$(xcrun llvm-cov report "${TEST_BINARY}" \
    -instr-profile "${MERGED_PROFILE}" \
    -ignore-filename-regex='.build|Tests')"
printf '%s\n' "${REPORT}"

TOTAL_LINE_COVERAGE="$(
    printf '%s\n' "${REPORT}" |
        awk '/^TOTAL/ { value=$(NF-3); sub(/%$/, "", value); print value }'
)"

if [[ -n "${THRESHOLD}" ]]; then
    awk -v actual="${TOTAL_LINE_COVERAGE}" -v threshold="${THRESHOLD}" 'BEGIN {
        if (actual + 0 < threshold + 0) {
            printf "Raw SwiftPM line coverage %.2f%% is below the %.2f%% threshold.\n", actual, threshold > "/dev/stderr"
            exit 1
        }
        printf "Raw SwiftPM line coverage %.2f%% meets the %.2f%% threshold.\n", actual, threshold
    }'
fi
