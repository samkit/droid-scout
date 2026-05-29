#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README_PATH="${ROOT_DIR}/README.md"

cd "${ROOT_DIR}"
mkdir -p .build
REPORT_PATH="$(mktemp "${ROOT_DIR}/.build/coverage-report.XXXXXX")"

scripts/test-coverage.sh "$@" | tee "${REPORT_PATH}"

COVERAGE="$(
  awk '/^Line coverage / {
    value=$3
    sub(/%$/, "", value)
    print value
  }' "${REPORT_PATH}" | tail -n 1
)"

if [[ -z "${COVERAGE}" ]]; then
  echo "Could not parse line coverage from ${REPORT_PATH}." >&2
  exit 1
fi

sed -i '' -E \
  "s#coverage-[0-9]+([.][0-9]+)?%25-#coverage-${COVERAGE}%25-#" \
  "${README_PATH}"

echo "Updated README coverage badge to ${COVERAGE}%."
