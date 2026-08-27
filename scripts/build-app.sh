#!/bin/bash
# Assembles Multiemu.app from the SwiftPM build products.
#
# SwiftPM cannot emit an application bundle, so the bundle is assembled here.
# That is deliberate rather than a workaround: the layout, Info.plist, icon and
# signing all stay visible in one reviewable script, which is exactly what the
# release pipeline in Milestone 21 has to extend.
#
#   scripts/build-app.sh [--identity "Developer ID Application: ..."]
#                        [--with-helpers <dir>] [--out <dir>] [--version <x.y.z>]
#
# --with-helpers copies qemu-system-* / qemu-img into Contents/Helpers and signs
# them with the hypervisor entitlement, which is how a shipping build resolves
# its backend. Without it the app falls back to a development QEMU on this Mac
# and says so in its activity log.
set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY="-"
HELPERS_SOURCE=""
OUT_DIR="build"
VERSION="0.9.0"
BUILD_NUMBER="$(date +%Y%m%d)"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --with-helpers) HELPERS_SOURCE="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

APP="${OUT_DIR}/Multiemu.app"
CONTENTS="${APP}/Contents"

# Guarded deletion: only ever inside the chosen output directory.
discard() {
  case "$1" in
    ""|"/"|"$HOME") echo "refusing to delete '$1'" >&2; exit 70 ;;
  esac
  rm -rf "$1"
}

echo "Building Multiemu ${VERSION} (${BUILD_NUMBER})"
swift build -c release --product Multiemu
swift build -c release --product multiemu-icon

echo "Assembling ${APP}"
discard "$APP"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources" "${CONTENTS}/Helpers"

cp .build/release/Multiemu "${CONTENTS}/MacOS/Multiemu"

# --- Icon, generated from source ---
ICONSET="${OUT_DIR}/Multiemu.iconset"
discard "$ICONSET"
.build/release/multiemu-icon "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "${CONTENTS}/Resources/Multiemu.icns"
discard "$ICONSET"

# --- Info.plist ---
cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Multiemu</string>
	<key>CFBundleDisplayName</key>
	<string>Multiemu</string>
	<key>CFBundleIdentifier</key>
	<string>com.multiemu.Multiemu</string>
	<key>CFBundleExecutable</key>
	<string>Multiemu</string>
	<key>CFBundleIconFile</key>
	<string>Multiemu</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD_NUMBER}</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Multiemu. Original work; no third-party assets are bundled.</string>
</dict>
</plist>
PLIST

# --- Optional bundled backend ---
if [ -n "$HELPERS_SOURCE" ]; then
  # A plain copy. It does NOT relocate dylibs or bring in QEMU's ROMs, so a
  # bundle made this way links to /opt/homebrew and dies on the first guest with
  # `failed to find romfile`. For a distributable build use
  # `scripts/build-qemu.sh bundle`, which does the whole job; this path is for a
  # local build against a QEMU that is already self-contained.
  echo "Copying helpers from ${HELPERS_SOURCE} (no dylib relocation — see the note above)"
  for tool in qemu-system-aarch64 qemu-system-x86_64 qemu-img; do
    if [ -f "${HELPERS_SOURCE}/${tool}" ]; then
      cp "${HELPERS_SOURCE}/${tool}" "${CONTENTS}/Helpers/${tool}"
      # The hypervisor entitlement belongs on the backend, never on the app.
      scripts/sign-helper.sh "${CONTENTS}/Helpers/${tool}" \
        Resources/entitlements/MultiemuQEMUHelper.entitlements "$IDENTITY" >/dev/null
    fi
  done
else
  echo "No helpers bundled; the app will look for a development QEMU on this Mac."
fi

# --- Licence materials, BEFORE signing ---
#
# Order matters and is easy to get wrong: adding anything to Contents/ after
# codesign breaks the bundle's seal, and the failure does not surface until
# something verifies it later. Collecting licences here means the signature
# covers them.
LICENSE_ARGS=()
if [ -n "${QEMU_SOURCE:-}" ]; then
  LICENSE_ARGS+=(--qemu-source "$QEMU_SOURCE")
fi
scripts/collect-licenses.sh "$APP" "${LICENSE_ARGS[@]+"${LICENSE_ARGS[@]}"}" | sed 's/^/  /'

# --- Signing, inside-out: helpers above, then the bundle ---
EXTRA=()
if [ "$IDENTITY" != "-" ]; then
  EXTRA+=(--options runtime --timestamp)
fi
codesign --force --sign "$IDENTITY" \
  --entitlements Resources/entitlements/Multiemu.app.entitlements \
  "${EXTRA[@]+"${EXTRA[@]}"}" "$APP"

echo
echo "Verification"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
plutil -lint "${CONTENTS}/Info.plist" | sed 's/^/  /'
echo "  bundle size: $(du -sh "$APP" | cut -f1)"
echo
echo "Built ${APP}"
