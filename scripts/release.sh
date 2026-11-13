#!/bin/bash
# Publishes a release: builds the DMG for the version in VERSION and uploads it to
# GitHub (smoker070/multiemu). Installed copies offer the update on their next launch.
#   scripts/release.sh "What changed, one line per item"
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$HERE/VERSION")"
NOTES="${1:?Pass the release notes as the first argument}"
"$HERE/build.sh" --dmg
gh release create "v$VERSION" "$HERE/dist/Multiemu-$VERSION.dmg" \
  -R smoker070/multiemu --title "Multiemu $VERSION" --notes "$NOTES"
