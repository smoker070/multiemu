#!/bin/bash
# Packages a built app into a distributable disk image.
#
# Read-only and compressed (UDZO), with an APPSLINK symlink so the install is a
# drag (the symlink points at the system applications folder). Nothing here signs anything: signing and notarization happen in
# scripts/release.sh, where the credential boundary is.
#
# Usage: scripts/make-dmg.sh [app bundle] [output.dmg]
set -euo pipefail

cd "$(dirname "$0")/.."

APP="${1:-build/Multiemu.app}"
NAME="$(basename "$APP" .app)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
OUTPUT="${2:-build/${NAME}-${VERSION}.dmg}"
INSTALL_TARGET="/Applications"

[ -d "$APP" ] || { echo "no app bundle at $APP" >&2; exit 66; }

staging="$(mktemp -d)"
discard() { [ -n "${1:-}" ] && [ -d "$1" ] && /bin/rm -rf -- "$1"; }
cleanup() {
  # Detach before discarding, or the staging directory cannot be removed and the
  # next run inherits a stale mount.
  [ -n "${mounted:-}" ] && hdiutil detach "$mounted" -quiet 2>/dev/null || true
  discard "$staging"
}
trap cleanup EXIT

echo "Staging ${NAME} ${VERSION}..."
cp -R "$APP" "${staging}/"
ln -s "$INSTALL_TARGET" "${staging}/Applications"

# The licence materials are visible in the image as well as inside the bundle,
# so someone who never opens the app can still find them.
if [ -d "${APP}/Contents/Resources/licenses" ]; then
  cp -R "${APP}/Contents/Resources/licenses" "${staging}/Licenses"
fi

/bin/rm -f -- "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"

echo "Building disk image..."
hdiutil create \
  -volname "${NAME} ${VERSION}" \
  -srcfolder "$staging" \
  -ov -format UDZO \
  -quiet \
  "$OUTPUT"

echo "Verifying..."
hdiutil verify "$OUTPUT" -quiet && echo "  checksum: valid"

# Mount it and check the app is really in there and still passes its own
# signature check. A DMG that builds but carries a broken bundle is worse than a
# build failure, because it looks finished.
mounted="$(hdiutil attach "$OUTPUT" -nobrowse -readonly | awk -F'\t' '/\/Volumes\// {print $NF}' | tail -1)"
if [ -z "$mounted" ]; then
  echo "  could not mount the image" >&2
  exit 1
fi
if [ ! -d "${mounted}/${NAME}.app" ]; then
  echo "  the image does not contain ${NAME}.app" >&2
  exit 1
fi
echo "  contains: $(ls "$mounted" | tr '\n' ' ')"
if codesign --verify --deep --strict "${mounted}/${NAME}.app" 2>&1 | sed 's/^/  /'; then
  echo "  the app inside the image verifies"
else
  echo "  the app inside the image FAILS its signature check" >&2
  exit 1
fi
hdiutil detach "$mounted" -quiet
mounted=""

size=$(du -h "$OUTPUT" | cut -f1 | tr -d ' ')
echo ""
echo "Disk image: $OUTPUT ($size)"
