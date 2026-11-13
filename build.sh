#!/bin/bash
# Builds Multiemu.app into dist/.
#   ./build.sh            build only           -> dist/Multiemu.app
#   ./build.sh --install  build and install    -> /Applications/Multiemu.app
#   ./build.sh --dmg      build and package    -> dist/Multiemu-<version>.dmg
# Multiemu contains no Android code: it drives Google's emulator in ~/Library/Android/sdk.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(tr -d '[:space:]' < "$HERE/VERSION")"
DIST="$HERE/dist"
APP="$DIST/Multiemu.app"

( cd "$HERE/App" && swift build -c release -j 2 )
BIN="$HERE/App/.build/release/Multiemu"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Multiemu"
# rootAVD (GPL-3.0, gitlab.com/newbit/rootAVD): used only for "Play Store + Root"
# devices. It runs from a working copy in Application Support, never from the bundle.
mkdir -p "$APP/Contents/Resources/rootAVD"
cp -R "$HERE/rootAVD-src/." "$APP/Contents/Resources/rootAVD/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Multiemu</string>
  <key>CFBundleDisplayName</key><string>Multiemu</string>
  <key>CFBundleIdentifier</key><string>io.github.smoker070.multiemu</string>
  <key>CFBundleExecutable</key><string>Multiemu</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict></plist>
PL
cp "$HERE/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep -s - "$APP" >/dev/null
echo "Built: $APP ($VERSION)"

if [ "${1:-}" = "--install" ]; then
  # The previous copy goes to the Trash (recoverable), never rm.
  for old in "/Applications/Multiemu.app" "/Applications/Android.app"; do
    [ -d "$old" ] && osascript -e "tell application \"Finder\" to delete POSIX file \"$old\"" >/dev/null
  done
  ditto "$APP" "/Applications/Multiemu.app"
  echo "Installed: /Applications/Multiemu.app"
fi

if [ "${1:-}" = "--dmg" ]; then
  STAGE="$(mktemp -d)"
  ditto "$APP" "$STAGE/Multiemu.app"
  ln -s /Applications "$STAGE/Applications"
  DMG="$DIST/Multiemu-$VERSION.dmg"
  rm -f "$DMG"
  hdiutil create -volname "Multiemu $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
  rm -rf "$STAGE"
  echo "DMG: $DMG"
fi
