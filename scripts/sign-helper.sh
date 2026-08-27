#!/bin/bash
# Signs a Multiemu helper executable with an entitlements file.
#
#   scripts/sign-helper.sh <binary> <entitlements.plist> [signing-identity]
#
# The signing identity defaults to "-" (ad-hoc), which is what local
# development uses: on macOS an ad-hoc signature carrying
# com.apple.security.hypervisor is sufficient to call Hypervisor.framework on
# the machine that produced it.
#
# Release builds pass a real Developer ID identity and add --options runtime,
# which this script applies automatically for non-ad-hoc identities because
# notarization requires the hardened runtime.
#
# No signing identity, password, or credential is ever read from or written to
# this repository; the identity name is looked up in the login keychain.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
fi

binary="$1"
entitlements="$2"
identity="${3:--}"

[ -f "$binary" ]       || { echo "no such binary: $binary" >&2; exit 66; }
[ -f "$entitlements" ] || { echo "no such entitlements file: $entitlements" >&2; exit 66; }

extra=()
if [ "$identity" != "-" ]; then
  # Developer ID signing: hardened runtime and a secure timestamp are both
  # prerequisites for notarization.
  extra+=(--options runtime --timestamp)
fi

echo "Signing $(basename "$binary")"
echo "  identity     : $identity"
echo "  entitlements : $entitlements"
[ "${#extra[@]}" -gt 0 ] && echo "  extra        : ${extra[*]}"

codesign --force --sign "$identity" --entitlements "$entitlements" "${extra[@]+"${extra[@]}"}" "$binary"

echo
echo "Verification"
codesign --verify --verbose=2 "$binary" 2>&1 | sed 's/^/  /'
echo "  entitlements now present:"
codesign -d --entitlements - "$binary" 2>/dev/null | grep -E "Key|Bool|String" | sed 's/^/    /' || true
