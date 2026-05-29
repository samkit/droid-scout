#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THRESHOLD="${1:-98}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
IGNORE_REGEX='.build|Tests|PopoverView.swift|SettingsView.swift|StatusBarController.swift|main.swift|DroidScoutModel.swift|ActionServices.swift|ADBServices.swift|SystemActions.swift'

cd "${ROOT_DIR}"
mkdir -p .build
SCRATCH_DIR="$(mktemp -d "${ROOT_DIR}/.build/cov-base.XXXXXX")"

find_codecov_dir() {
    find "$1" -type d -path '*/debug/codecov' -print -quit
}

find_test_binary() {
    find "$1" -path '*/DroidScoutPackageTests.xctest/Contents/MacOS/DroidScoutPackageTests' -type f -print -quit
}

env DEVELOPER_DIR="${DEVELOPER_DIR}" swift test \
    --scratch-path "${SCRATCH_DIR}" \
    --disable-sandbox \
    --no-parallel \
    --enable-code-coverage

CODECOV_DIR="$(find_codecov_dir "${SCRATCH_DIR}")"
TEST_BINARY="$(find_test_binary "${SCRATCH_DIR}")"
PROFILE="${CODECOV_DIR}/default.profdata"

if [[ -z "${CODECOV_DIR}" || -z "${TEST_BINARY}" || ! -f "${PROFILE}" ]]; then
    echo "Could not locate SwiftPM coverage outputs." >&2
    exit 1
fi

REPORT="$(xcrun llvm-cov report "${TEST_BINARY}" -instr-profile "${PROFILE}" -ignore-filename-regex="${IGNORE_REGEX}")"
printf '%s\n' "${REPORT}"

TOTAL_LINE_COVERAGE="$(
    printf '%s\n' "${REPORT}" |
        awk '/^TOTAL/ { value=$(NF-3); sub(/%$/, "", value); print value }'
)"

awk -v actual="${TOTAL_LINE_COVERAGE}" -v threshold="${THRESHOLD}" 'BEGIN {
    if (actual + 0 < threshold + 0) {
        printf "Line coverage %.2f%% is below the %.2f%% threshold.\n", actual, threshold > "/dev/stderr"
        exit 1
    }
    printf "Line coverage %.2f%% meets the %.2f%% threshold.\n", actual, threshold
}'
