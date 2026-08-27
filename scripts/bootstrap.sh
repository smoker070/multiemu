#!/bin/bash
# Prints the developer setup Multiemu needs. Installs nothing on its own —
# the commands are shown so they can be reviewed and run deliberately.
set -euo pipefail

cat <<'TEXT'
Multiemu developer bootstrap
============================

Milestone 1 needs nothing beyond Xcode / the Command Line Tools:

    swift build
    swift test
    swift run multiemu-probe

From Milestone 2 onward, a development QEMU and build tools are needed.
Review and run these yourself:

    brew install qemu ninja meson pkg-config

    # ADB, for Milestone 8 development only. Shipping builds use an ADB
    # client built from AOSP source, not this binary.
    brew install --cask android-platform-tools

A Homebrew QEMU is a *development convenience only*. Shipping builds use a
QEMU built by scripts/build-qemu.sh (Milestone 2), signed with Developer ID,
the hardened runtime and com.apple.security.hypervisor, and shipped with its
corresponding source. See docs/DEPENDENCIES-AND-LICENSING.md.

Optional reference oracle (never bundled, never invoked by the app): install
Android Studio separately to compare against Google's own emulator when
diagnosing guest boot problems.
TEXT
