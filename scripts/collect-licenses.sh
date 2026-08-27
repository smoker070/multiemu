#!/bin/bash
# Assembles the licence materials that must ship inside the app.
#
# This is a COMPLIANCE GATE, not a formality. QEMU is GPL-2.0-only, and a build
# that bundles it without the corresponding source and licence text is not
# distributable. So this script REFUSES to prepare such a bundle rather than
# warning about it: a warning in a build log is not a thing anyone reads before
# uploading a DMG.
#
# Usage:
#   scripts/collect-licenses.sh <app bundle> [--qemu-source <dir>] [--source-url <url>]
set -euo pipefail

cd "$(dirname "$0")/.."

APP="${1:-build/Multiemu.app}"
QEMU_SOURCE=""
# Defaulted rather than left empty, because the failure mode of forgetting it is
# a licence document shipping the literal text "[SOURCE URL NOT SET]" — a
# written offer with no address is not an offer. Override for a fork.
SOURCE_URL="${MULTIEMU_SOURCE_URL:-https://github.com/ismoil/multiemu}"
HOLDER="${MULTIEMU_COPYRIGHT_HOLDER:-the Multiemu authors}"

shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --qemu-source) QEMU_SOURCE="$2"; shift 2 ;;
    --source-url) SOURCE_URL="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

[ -d "$APP" ] || { echo "no app bundle at $APP" >&2; exit 66; }

LICENSES="${APP}/Contents/Resources/licenses"
rm -rf "$LICENSES"
mkdir -p "$LICENSES"

year=$(date +%Y)

# --- Our own notice, and the component inventory ---
cat > "${LICENSES}/NOTICE.txt" <<NOTICE
Multiemu
Copyright (c) ${year} ${HOLDER}.

Multiemu's own code, artwork, icons, branding and layout are original works and
are licensed under the MIT licence; see the LICENSE file in the source
repository. That licence covers Multiemu's own code only, not the components
listed below.

This application includes or interoperates with the components below. Where a
component's licence requires it, its full text and corresponding source are
provided alongside this notice.
NOTICE

# --- QEMU, if it is actually being shipped ---
helpers="${APP}/Contents/Helpers"
bundles_qemu=false
if [ -d "$helpers" ] && ls "$helpers" 2>/dev/null | grep -q "^qemu"; then
  bundles_qemu=true
fi

if [ "$bundles_qemu" = true ]; then
  if [ -z "$QEMU_SOURCE" ] || [ ! -d "$QEMU_SOURCE" ]; then
    cat >&2 <<REFUSE
REFUSED: this bundle contains QEMU binaries in Contents/Helpers, but no QEMU
source tree was given.

QEMU is GPL-2.0-only. Distributing the binary obliges us to provide the
corresponding source for that exact build, together with its licence text.
Shipping without them is not a paperwork gap; it is a licence violation.

Build QEMU from pinned source first:

    scripts/build-qemu.sh

then pass its source tree:

    scripts/collect-licenses.sh $APP --qemu-source <dir>
REFUSE
    exit 65
  fi

  mkdir -p "${LICENSES}/qemu"
  copied=0
  for file in COPYING COPYING.LIB LICENSE; do
    if [ -f "${QEMU_SOURCE}/${file}" ]; then
      cp "${QEMU_SOURCE}/${file}" "${LICENSES}/qemu/${file}"
      copied=$((copied + 1))
    fi
  done
  if [ "$copied" -eq 0 ]; then
    echo "REFUSED: no COPYING file found in ${QEMU_SOURCE}" >&2
    exit 65
  fi

  # Record exactly which source this binary corresponds to. "A recent QEMU" is
  # not what the licence asks for.
  {
    echo "QEMU source corresponding to the binaries in Contents/Helpers"
    echo ""
    if [ -f "${QEMU_SOURCE}/VERSION" ]; then
      echo "version:  $(cat "${QEMU_SOURCE}/VERSION")"
    fi
    if git -C "$QEMU_SOURCE" rev-parse HEAD >/dev/null 2>&1; then
      echo "commit:   $(git -C "$QEMU_SOURCE" rev-parse HEAD)"
      echo "describe: $(git -C "$QEMU_SOURCE" describe --tags --always 2>/dev/null || echo unknown)"
    fi
    echo "collected: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${LICENSES}/qemu/SOURCE-VERSION.txt"

  cat > "${LICENSES}/qemu/WRITTEN-OFFER.txt" <<OFFER
Written offer for QEMU source code
==================================

This application includes QEMU, licensed under the GNU General Public License
version 2. The complete corresponding source code for the QEMU binaries in
Multiemu.app/Contents/Helpers, together with the build scripts and any patches
used to produce them, is available at:

    ${SOURCE_URL:-[SOURCE URL NOT SET — set MULTIEMU_SOURCE_URL before release]}

The exact revision is recorded in SOURCE-VERSION.txt beside this file.

If that location is unavailable, the source will be provided on request, on a
physical medium, for no more than the cost of distribution. This offer is valid
for three years from the date this copy was distributed.

The full licence text is in COPYING beside this file.
OFFER

  {
    echo ""
    echo "QEMU — GPL-2.0-only"
    echo "  Spawned as a separate child process and controlled over a socket."
    echo "  Never linked into Multiemu."
    echo "  Licence: licenses/qemu/COPYING"
    echo "  Source:  licenses/qemu/WRITTEN-OFFER.txt"
  } >> "${LICENSES}/NOTICE.txt"

  if [ -z "$SOURCE_URL" ]; then
    echo "WARNING: MULTIEMU_SOURCE_URL is not set, so the written offer has no URL." >&2
    echo "         Set it before distributing this build." >&2
  fi
else
  {
    echo ""
    echo "This build bundles no third-party binaries. QEMU, when present, is"
    echo "supplied separately by the developer's own Homebrew installation and"
    echo "is not redistributed."
  } >> "${LICENSES}/NOTICE.txt"
fi

echo "Licence materials in ${LICENSES}:"
find "$LICENSES" -type f | sed "s|${LICENSES}/|  |"
