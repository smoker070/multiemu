#!/bin/bash
# The release pipeline: build, sign, notarize, staple, package, assess.
#
# Runs end to end in two modes.
#
#   --rehearsal  Exercise every step that does not need Apple credentials, and
#                say plainly which steps were skipped. Signs ad-hoc. The output
#                is NOT distributable and the script says so.
#
#   --unsigned   An open-source release. Produces a DMG that is deliberately
#                NOT signed by a Developer ID and NOT notarized, names itself
#                so in the file name, and prints what a user must do to open
#                it. This is how Multiemu ships: the project is MIT and has no
#                Apple Developer membership behind it.
#
#   (default)    A signed, notarized release. Requires a Developer ID and
#                notary credentials, and REFUSES to produce a DMG without them
#                rather than emitting something that looks finished. Not the
#                path this project uses; kept because the licence permits
#                anyone to make signed builds of their own.
#
# Credentials never live in this repository. Store them once in the keychain:
#
#     xcrun notarytool store-credentials multiemu-notary \
#         --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific>
#
# and export MULTIEMU_SIGN_IDENTITY to the Developer ID Application identity.
set -euo pipefail

cd "$(dirname "$0")/.."

REHEARSAL=false
UNSIGNED=false
WITH_HELPERS=false
QEMU_SOURCE="${MULTIEMU_QEMU_SOURCE:-}"
RELEASE_VERSION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --rehearsal) REHEARSAL=true; shift ;;
    --unsigned) UNSIGNED=true; shift ;;
    --with-helpers) WITH_HELPERS=true; shift ;;
    --qemu-source) QEMU_SOURCE="$2"; shift 2 ;;
    --version) RELEASE_VERSION="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

IDENTITY="${MULTIEMU_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${MULTIEMU_NOTARY_PROFILE:-multiemu-notary}"
APP="build/Multiemu.app"

step() { printf '\n=== %s ===\n' "$1"; }
note() { printf '  %s\n' "$1"; }

skipped=()
skip() { skipped+=("$1"); note "SKIPPED — $1"; }

# --- 1. Preflight -----------------------------------------------------------

step "Preflight"

for tool in codesign hdiutil xcrun; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 65; }
done
note "codesign, hdiutil and xcrun are present"

identities=$(security find-identity -v -p codesigning 2>/dev/null | grep -c "Developer ID Application" || true)
if [ -z "$IDENTITY" ] && [ "$identities" -gt 0 ]; then
  IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
fi

has_identity=false
[ -n "$IDENTITY" ] && has_identity=true
if [ "$has_identity" = true ]; then
  note "signing identity: $IDENTITY"
else
  note "no Developer ID Application identity found in the keychain"
fi

has_notary=false
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  has_notary=true
  note "notary credentials: keychain profile \"$NOTARY_PROFILE\""
else
  note "no usable notary credentials for profile \"$NOTARY_PROFILE\""
fi

if [ "$REHEARSAL" = false ] && [ "$UNSIGNED" = false ]; then
  if [ "$has_identity" = false ]; then
    cat >&2 <<'REFUSE'

REFUSED: a release needs a Developer ID Application identity.

Without one the result cannot be notarized, and Gatekeeper will reject it on
every Mac but this one. Producing a DMG anyway would look like a finished
release and behave like a broken one.

Either rehearse the pipeline:

    scripts/release.sh --rehearsal

or produce the unsigned build this project actually ships:

    scripts/release.sh --unsigned

REFUSE
    exit 65
  fi
  if [ "$has_notary" = false ]; then
    echo "REFUSED: a release needs notary credentials (see the header of this script)." >&2
    exit 65
  fi
fi

# --- 2. Tests ---------------------------------------------------------------

step "Tests"
swift test 2>&1 | tail -1 | sed 's/^/  /'

# --- 3. Build and sign ------------------------------------------------------

step "Build"
build_args=()
# NOT build-app.sh's own --with-helpers. That copies the binaries and signs
# them, which produces a bundle that passes every static check and then dies on
# the first guest: the dylibs still point at /opt/homebrew and QEMU's ROMs are
# missing entirely. `build-qemu.sh bundle` does the whole job — relocation, data
# files, ad-hoc re-signing — and is run after the app is assembled.
#
# The old line here also passed --with-helpers with no directory, so build-app
# would have consumed the next flag as its argument.
[ -n "$RELEASE_VERSION" ] && build_args+=(--version "$RELEASE_VERSION")
if [ "$has_identity" = true ]; then
  CODESIGN_IDENTITY="$IDENTITY" QEMU_SOURCE="$QEMU_SOURCE" \
    scripts/build-app.sh "${build_args[@]+"${build_args[@]}"}" 2>&1 | tail -6 | sed 's/^/  /'
else
  QEMU_SOURCE="$QEMU_SOURCE" \
    scripts/build-app.sh "${build_args[@]+"${build_args[@]}"}" 2>&1 | tail -6 | sed 's/^/  /'
fi

if [ "$WITH_HELPERS" = true ]; then
  step "Bundle the backend"
  scripts/build-qemu.sh bundle "$APP" 2>&1 | sed 's/^/  /'

  # Re-sign the app AFTER adding the backend, or its seal is broken.
  #
  # `build-app.sh` already made this exact mistake once with licence files, and
  # its comment says so: anything added to Contents/ after codesign invalidates
  # the signature, and nothing complains until something verifies later. Adding
  # 3 helpers, 20 dylibs and 92 MB of ROMs is a much bigger version of the same
  # thing — the mount-and-verify step caught it with "a sealed resource is
  # missing or invalid", which is precisely why that step exists.
  #
  # Re-run the licence gate now that QEMU is actually IN the bundle.
  #
  # `build-app.sh` collects licences before it signs, which is correct for the
  # app on its own — but at that point Contents/Helpers is empty, so the gate
  # looked at a bundle with no third-party binaries and wrote a notice saying
  # exactly that. Three QEMU binaries and 92 MB of its ROMs then arrived
  # afterwards. The notice was false and the GPL source requirement went
  # unchecked; a compliance gate that runs before the thing it gates is not a
  # gate at all.
  step "Licences (re-checked with the backend present)"
  license_args=()
  [ -n "$QEMU_SOURCE" ] && license_args+=(--qemu-source "$QEMU_SOURCE")
  scripts/collect-licenses.sh "$APP" "${license_args[@]+"${license_args[@]}"}" 2>&1 | sed 's/^/  /'

  # Inside-out: build-qemu.sh signed the dylibs and helpers, so only the
  # enclosing bundle is left.
  resign_extra=()
  [ "$IDENTITY" != "-" ] && [ -n "$IDENTITY" ] && resign_extra+=(--options runtime --timestamp)
  codesign --force --sign "${IDENTITY:--}" \
    --entitlements Resources/entitlements/Multiemu.app.entitlements \
    "${resign_extra[@]+"${resign_extra[@]}"}" "$APP"
  codesign --verify --deep --strict "$APP" 2>&1 | sed 's/^/  /'
  note "re-signed the app around the bundled backend"
fi

step "Signature"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Identifier|Format|Signature|TeamIdentifier|flags" | sed 's/^/  /'
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - - | grep -q "com.apple"; then
  note "entitlements:"
  codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - - \
    | grep "<key>" | sed 's/.*<key>/    /; s|</key>||'
fi
if codesign -dv --verbose=2 "$APP" 2>&1 | grep -q "runtime"; then
  note "hardened runtime: enabled"
else
  note "hardened runtime: NOT enabled (only applied for a real signing identity)"
fi

# --- 4. Notarize and staple the app ----------------------------------------

step "Notarize the app"
if [ "$has_notary" = true ]; then
  ditto -c -k --keepParent "$APP" build/Multiemu-app.zip
  xcrun notarytool submit build/Multiemu-app.zip \
    --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | sed 's/^/  /'
  xcrun stapler staple "$APP" 2>&1 | sed 's/^/  /'
  xcrun stapler validate "$APP" 2>&1 | sed 's/^/  /'
else
  skip "notarizing and stapling the app: no notary credentials"
fi

# --- 5. Package -------------------------------------------------------------

step "Disk image"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")"
# The name carries the mode. A file called Multiemu-0.9.0.dmg that Gatekeeper
# refuses is indistinguishable, once downloaded, from a signed one that broke;
# a file called Multiemu-0.9.0-unsigned.dmg explains itself.
#
# Computed BEFORE the image is built and passed in, rather than assumed after.
# Naming it afterwards and hoping `make-dmg.sh` chose the same string produced a
# release that reported a path no file was ever written to.
if [ "$UNSIGNED" = true ]; then
  DMG="build/Multiemu-${VERSION}-unsigned.dmg"
else
  DMG="build/Multiemu-${VERSION}.dmg"
fi
scripts/make-dmg.sh "$APP" "$DMG" 2>&1 | sed 's/^/  /' 

step "Sign the disk image"
if [ "$has_identity" = true ]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  codesign --verify --verbose=2 "$DMG" 2>&1 | sed 's/^/  /'
else
  skip "signing the disk image: no Developer ID"
fi

step "Notarize the disk image"
if [ "$has_notary" = true ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | sed 's/^/  /'
  xcrun stapler staple "$DMG" 2>&1 | sed 's/^/  /'
  xcrun stapler validate "$DMG" 2>&1 | sed 's/^/  /'
else
  skip "notarizing and stapling the disk image: no notary credentials"
fi

# --- 6. Assess as Gatekeeper would -----------------------------------------

step "Gatekeeper assessment"
set +e
spctl -a -vvv "$APP" 2>&1 | sed 's/^/  app: /'
app_verdict=$?
spctl -a -t open --context context:primary-signature -vvv "$DMG" 2>&1 | sed 's/^/  dmg: /'
dmg_verdict=$?
set -e

# --- 7. Report --------------------------------------------------------------

step "Result"
note "app: $APP"
note "dmg: $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
note "gatekeeper accepted the app: $([ $app_verdict -eq 0 ] && echo yes || echo no)"
note "gatekeeper accepted the dmg: $([ $dmg_verdict -eq 0 ] && echo yes || echo no)"

if [ ${#skipped[@]} -gt 0 ]; then
  echo
  echo "  Steps that did not run:"
  for entry in "${skipped[@]}"; do echo "    - $entry"; done
fi

echo
if [ "$REHEARSAL" = true ]; then
  cat <<'REHEARSED'
  This was a REHEARSAL. The disk image is not signed by a Developer ID and is
  not notarized, so Gatekeeper rejects it on any Mac. Do not distribute it.
  The rejection above is the expected result, and is what proves the assessment
  is actually checking something.
REHEARSED
  exit 0
fi

if [ "$UNSIGNED" = true ]; then
  cat <<UNSIGNED_NOTE
  UNSIGNED release: $DMG

  Gatekeeper rejects this, and that is correct — it is not signed by a
  Developer ID and not notarized. The rejection above is the assessment doing
  its job, not a build failure.

  Tell users to run, once, after copying the app out of the image:

      xattr -d com.apple.quarantine /Applications/Multiemu.app

  or to right-click the app and choose Open, which offers the same override
  through the interface. Anyone who would rather not do either can build from
  source: scripts/build-app.sh needs no credentials at all.
UNSIGNED_NOTE
  exit 0
fi

if [ $app_verdict -eq 0 ] && [ $dmg_verdict -eq 0 ]; then
  echo "  Release ready: $DMG"
  exit 0
fi
echo "  Gatekeeper rejected the result; this build is not distributable." >&2
exit 1
