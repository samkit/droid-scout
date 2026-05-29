#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "${ROOT_DIR}"

tests=(
  androidDeviceDerivedPropertiesCoverPhysicalAndEmulatorDevices
  localStorePersistsCapsAndRedactsDiagnostics
  adbDeviceParserExtractsStatesModelsAndTransportHints
  artifactIndexerScansGradleOutputsWithRealFilesystemFixtures
  processRunnerCapturesOutputExitCodesLaunchFailuresAndTimeouts
  installCoordinatorRunsRealADBScriptAndReportsStateChanges
  packageStatePollerUsesRealADBAndSkipsOfflineDevices
)

for test_name in "${tests[@]}"; do
  swift test --disable-sandbox --filter "${test_name}"
done
