#!/bin/bash
# Builds the QEMU that Multiemu ships, from a pinned upstream release.
#
# Why we build QEMU rather than using Homebrew's:
#
#   1. Self-containment. This is the reason that matters for an open-source
#      release. Someone who downloads the DMG has no Homebrew QEMU, and an
#      emulator that cannot start a guest until the user installs a second
#      package is not distributable.
#   2. Licensing. QEMU is GPL-2.0-only. We must publish the corresponding source
#      of the exact binary we ship, so that binary must come from a pinned tag we
#      control - not from whatever Homebrew resolved that day.
#   3. Attack surface. Most QEMU targets, devices and backends are things an
#      Android emulator will never use. Disabling them removes code we would
#      otherwise have to ship and defend.
#
# Signing is deliberately NOT a reason any more: Multiemu ships unsigned (see
# docs/RELEASE.md). Ad-hoc signatures are still applied so the bundle verifies
# and the helper launches.
#
#   scripts/build-qemu.sh fetch
#   scripts/build-qemu.sh configure
#   scripts/build-qemu.sh build
#   scripts/build-qemu.sh bundle <path-to-Multiemu.app>
set -euo pipefail

cd "$(dirname "$0")/.."

# Pinned upstream release. Bumping this REQUIRES publishing the matching source
# tarball alongside the next Multiemu release.
#
# 11.1.0 and not something older, because that is the version every measurement
# in docs/VERIFY.md was taken against: the absence of virtio-sound, the
# output-only `usb-audio`, the D-Bus display and audio backends, the QMP
# behaviour. Shipping a QEMU nobody verified against would silently invalidate
# the lot.
QEMU_VERSION="${QEMU_VERSION:-11.1.0}"
QEMU_URL="https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz"
# The tarball and its checksum stay in the repository: that is the source we are
# obliged to publish alongside any binary we ship.
VENDOR="vendor/qemu"

# Everything else happens somewhere else, and not by preference.
#
#     ERROR: main directory cannot contain spaces nor colons
#
# QEMU's build system refuses outright. This project's own path contains three
# spaces ("Ismoil Drive", "000 Files", "AI - automating systems"), so building
# in-tree is impossible here and would be for anyone who clones into a path with
# a space in it. Override with QEMU_WORK to build somewhere specific.
WORK="${QEMU_WORK:-/tmp/multiemu-qemu}"

# QEMU 11.1's build reads TOML, which is `tomllib` in the standard library from
# Python 3.11 and a separate `tomli` package before it. macOS ships 3.9, so
# configure stops with "found no usable tomli". Pointing it at a newer
# interpreter is cleaner than installing packages into the system Python.
QEMU_PYTHON="${QEMU_PYTHON:-/opt/homebrew/bin/python3.11}"
SOURCE="${WORK}/qemu-${QEMU_VERSION}"
BUILD="${WORK}/build-${QEMU_VERSION}"
PREFIX="${WORK}/install-${QEMU_VERSION}"

# Only the two targets Multiemu can ever use.
TARGETS="aarch64-softmmu,x86_64-softmmu"

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 64; }

case "${1:-}" in

fetch)
  mkdir -p "$VENDOR"
  tarball="${VENDOR}/qemu-${QEMU_VERSION}.tar.xz"
  [ -f "$tarball" ] || curl --fail --location --progress-bar --output "$tarball" "$QEMU_URL"
  echo "Checksum of the exact source we will ship:"
  shasum -a 256 "$tarball" | tee "${VENDOR}/qemu-${QEMU_VERSION}.tar.xz.sha256"
  echo
  echo "MANUAL STEP: verify this checksum and upstream's signature before continuing."
  echo "Silently trusting a download is how a supply-chain compromise enters a signed product."
  mkdir -p "$WORK"
  tar -xf "$tarball" -C "$WORK"
  echo "Extracted to $SOURCE"
  echo "(The tarball stays in $VENDOR — that is the source we must publish.)"
  ;;

configure)
  [ -d "$SOURCE" ] || { echo "run '$0 fetch' first" >&2; exit 66; }
  mkdir -p "$BUILD"
  python_flag=()
  [ -x "$QEMU_PYTHON" ] && python_flag=(--python="$QEMU_PYTHON")
  ( cd "$BUILD" && "../qemu-${QEMU_VERSION}/configure" \
      "${python_flag[@]}" \
      --prefix="$PREFIX" \
      --target-list="$TARGETS" \
      --enable-hvf \
      --enable-coreaudio \
      --enable-slirp \
      --enable-dbus-display \
      --disable-cocoa \
      --disable-sdl \
      --disable-gtk \
      --disable-vnc \
      --disable-spice \
      --disable-docs \
      --disable-guest-agent \
      --disable-debug-info \
      --disable-curl \
      --disable-libssh \
      --disable-bzip2 \
      --disable-snappy \
      --disable-lzo )
  echo
  echo "Review the configure summary above. Every 'yes' is a dylib we must bundle,"
  echo "sign and notarize, and attack surface we must justify."
  echo "--disable-cocoa is deliberate: QEMU never opens its own window."
  echo "--enable-dbus-display is NOT optional: every frame, every input event and"
  echo "the audio backend travel over it. Asking for it explicitly means a missing"
  echo "gio dependency fails here, loudly, instead of producing a QEMU that builds"
  echo "fine and cannot show a guest."
  ;;

build)
  [ -d "$BUILD" ] || { echo "run '$0 configure' first" >&2; exit 66; }
  ( cd "$BUILD" && make -j"$(sysctl -n hw.logicalcpu)" && make install )
  echo
  echo "Built binaries:"
  ls -la "$PREFIX/bin/" 2>/dev/null || true
  echo
  echo "Non-system dynamic dependencies (each must be bundled and re-signed):"
  for binary in "$PREFIX"/bin/qemu-system-*; do
    [ -f "$binary" ] || continue
    echo "  $(basename "$binary"):"
    otool -L "$binary" | tail -n +2 | grep -vE "/usr/lib/|/System/Library/" | sed 's/^/    /' || echo "    (none - fully system-linked)"
  done
  ;;

bundle)
  target="${2:-}"
  [ -n "$target" ] || usage
  [ -d "$PREFIX/bin" ] || { echo "nothing built; run '$0 build' first" >&2; exit 66; }
  helpers="${target}/Contents/Helpers"
  frameworks="${target}/Contents/Frameworks"
  mkdir -p "$helpers" "$frameworks"

  # Non-system dependencies of one Mach-O file.
  deps_of() {
    otool -L "$1" | tail -n +2 | awk '{print $1}' \
      | grep -vE "^/usr/lib/|^/System/Library/|^@" || true
  }

  # Copy a dylib in, give it an @rpath identity, and return its basename.
  #
  # Recursive on purpose: a dylib has dylibs. glib alone pulls in intl, pcre2
  # and charset, and relocating only what the helper links directly produces a
  # bundle that passes inspection and then fails to launch on a machine without
  # Homebrew — which is precisely the machine this is for.
  bring_in() {
    local dylib="$1" base
    base="$(basename "$dylib")"
    if [ ! -f "$frameworks/$base" ]; then
      cp "$dylib" "$frameworks/$base"
      chmod u+w "$frameworks/$base"
      install_name_tool -id "@rpath/$base" "$frameworks/$base"
      # Recurse before rewriting, so every level is present.
      local nested
      for nested in $(deps_of "$frameworks/$base"); do
        bring_in "$nested"
        install_name_tool -change "$nested" "@rpath/$(basename "$nested")" "$frameworks/$base"
      done
    fi
  }

  for binary in "$PREFIX"/bin/qemu-system-* "$PREFIX"/bin/qemu-img; do
    [ -f "$binary" ] || continue
    name="$(basename "$binary")"
    cp "$binary" "$helpers/$name"
    chmod u+w "$helpers/$name"

    for dylib in $(deps_of "$helpers/$name"); do
      bring_in "$dylib"
      install_name_tool -change "$dylib" "@rpath/$(basename "$dylib")" "$helpers/$name"
    done
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$helpers/$name" 2>/dev/null || true

    remaining="$(otool -L "$helpers/$name" | tail -n +2 \
      | grep -vE "/usr/lib/|/System/Library/|@rpath" || true)"
    if [ -n "$remaining" ]; then
      echo "$name still links outside the bundle:" >&2
      echo "$remaining" | sed 's/^/    /' >&2
      exit 1
    fi
    echo "Bundled $name"
  done

  # QEMU's data files: ROMs, firmware blobs and keymaps.
  #
  # Without these the binary links cleanly, reports its version, and then dies
  # the moment it is asked for a real machine:
  #
  #     -device virtio-net-pci: failed to find romfile "efi-virtio.rom"
  #
  # QEMU looks for them at `<executable>/../share/qemu`, so Contents/share/qemu
  # is the layout that needs no runtime flag and works however the helper is
  # invoked. Only a guest boot catches this — `--version` and `otool -L` both
  # look perfect without them.
  data_source="$PREFIX/share/qemu"
  if [ -d "$data_source" ]; then
    data_target="${target}/Contents/share/qemu"
    mkdir -p "$(dirname "$data_target")"
    /bin/rm -rf "$data_target"
    cp -R "$data_source" "$data_target"
    before="$(du -sh "$data_target" | cut -f1 | tr -d ' ')"

    # Drop UEFI firmware for architectures this build does not have targets for.
    # `--target-list` is aarch64 and x86_64; riscv, loongarch64 and 32-bit arm
    # firmware account for over 200 MB that no machine here can ever load.
    #
    # A deny-list of foreign architectures rather than an allow-list of wanted
    # files: getting an allow-list slightly wrong removes something a guest
    # needs, and the failure shows up as a boot that dies on a romfile — which
    # is exactly the bug this whole step exists to fix.
    for foreign in edk2-riscv-code.fd edk2-riscv-vars.fd \
                   edk2-loongarch64-code.fd edk2-loongarch64-vars.fd \
                   edk2-arm-code.fd edk2-arm-vars.fd; do
      /bin/rm -f "$data_target/$foreign"
    done

    echo "Bundled QEMU data files ($before -> $(du -sh "$data_target" | cut -f1 | tr -d ' ')"\
"; dropped firmware for architectures with no target)"
  else
    echo "no data files at $data_source — the helper will fail on the first real machine" >&2
    exit 1
  fi

  echo
  echo "Frameworks now in the bundle:"
  ls "$frameworks" | sed 's/^/    /'

  # Ad-hoc signing, because relocation invalidates whatever signature was there
  # and macOS will not load a dylib whose signature no longer matches its bytes.
  # Inside-out: dylibs first, then helpers.
  echo
  echo "Re-signing relocated binaries ad-hoc…"
  for dylib in "$frameworks"/*.dylib; do
    [ -f "$dylib" ] || continue
    codesign --force --sign - --timestamp=none "$dylib" 2>/dev/null
  done
  for helper in "$helpers"/qemu-*; do
    [ -f "$helper" ] || continue
    codesign --force --sign - --timestamp=none \
      --entitlements Resources/entitlements/MultiemuQEMUHelper.entitlements "$helper"
  done
  echo "Signed $(ls "$frameworks" | wc -l | tr -d ' ') dylibs and $(ls "$helpers" | wc -l | tr -d ' ') helpers ad-hoc."
  echo "For a Developer ID build, re-sign with scripts/sign-helper.sh and a real identity."
  ;;

*) usage ;;
esac
