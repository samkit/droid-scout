#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/prepare-release.sh <version> [--commit] [--tag] [--push]

Updates Info.plist, refreshes the README coverage badge, runs CI tests,
packages the release zip, and renders the Homebrew cask.

Options:
  --commit   Commit the release prep changes.
  --tag      Create tag v<version>. Requires --commit.
  --push     Push the current branch and tag when present.
USAGE
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="${ROOT_DIR}/packaging/Info.plist"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

VERSION="${1#v}"
shift
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

DO_COMMIT=0
DO_TAG=0
DO_PUSH=0

for arg in "$@"; do
  case "${arg}" in
    --commit) DO_COMMIT=1 ;;
    --tag) DO_TAG=1 ;;
    --push) DO_PUSH=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${DO_TAG}" -eq 1 && "${DO_COMMIT}" -ne 1 ]]; then
  echo "--tag requires --commit so the tag points at release prep changes." >&2
  exit 1
fi

cd "${ROOT_DIR}"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${INFO_PLIST}"
scripts/update-coverage-badge.sh
scripts/run-ci-tests.sh
scripts/package-cask-release.sh release
scripts/render-homebrew-cask.sh

if [[ "${DO_COMMIT}" -eq 1 ]]; then
  git add packaging/Info.plist README.md
  git commit -m "Prepare ${VERSION} release"
fi

if [[ "${DO_TAG}" -eq 1 ]]; then
  git tag "v${VERSION}"
fi

if [[ "${DO_PUSH}" -eq 1 ]]; then
  git push
  if [[ "${DO_TAG}" -eq 1 ]]; then
    git push origin "v${VERSION}"
  fi
fi

cat <<SUMMARY
Release prep complete for v${VERSION}.

Artifacts:
  .build/release/DroidScout-${VERSION}.zip
  .build/release/DroidScout-${VERSION}.zip.sha256
  .build/release/droid-scout.rb
SUMMARY
