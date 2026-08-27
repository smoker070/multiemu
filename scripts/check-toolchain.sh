#!/bin/bash
# Verifies the developer toolchain for Multiemu. Read-only: installs nothing.
set -uo pipefail

fail=0
ok()   { printf "  \033[32mok\033[0m    %s\n" "$1"; }
warn() { printf "  \033[33mwarn\033[0m  %s\n" "$1"; }
bad()  { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; fail=1; }

echo "Multiemu toolchain check"
echo

echo "Host"
macos_major=$(sw_vers -productVersion | cut -d. -f1)
if [ "$macos_major" -ge 14 ]; then
  ok "macOS $(sw_vers -productVersion) (build $(sw_vers -buildVersion))"
else
  bad "macOS $(sw_vers -productVersion) — macOS 14.0 or later is required"
fi

arch=$(uname -m)
case "$arch" in
  arm64)  ok "Apple Silicon host (arm64) — primary guest architecture will be arm64" ;;
  x86_64) ok "Intel host (x86_64) — primary guest architecture will be x86_64" ;;
  *)      bad "unrecognised architecture: $arch" ;;
esac

hv=$(sysctl -n kern.hv_support 2>/dev/null || echo 0)
if [ "$hv" = "1" ]; then
  ok "kern.hv_support = 1 (hardware virtualization available)"
else
  bad "kern.hv_support = $hv — no hardware virtualization; guests would be fully translated"
fi

if [ "$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)" = "1" ]; then
  warn "this macOS is itself running inside a VM; nested acceleration is generally unavailable"
fi

echo
echo "Toolchain"
if command -v swift >/dev/null 2>&1; then
  ok "$(swift --version 2>&1 | head -1)"
else
  bad "swift not found — install Xcode or the Command Line Tools"
fi

if xcode-select -p >/dev/null 2>&1; then
  ok "developer directory: $(xcode-select -p)"
else
  bad "xcode-select is not configured"
fi

echo
echo "External tools (not required for Milestone 1)"
for tool in qemu-system-aarch64 qemu-system-x86_64 qemu-img adb ninja meson; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool -> $(command -v "$tool")"
  else
    warn "$tool not found (needed from Milestone 2 onward)"
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  echo "Toolchain check passed. Next: scripts/probe.sh"
else
  echo "Toolchain check FAILED. Resolve the items marked FAIL before continuing."
fi
exit "$fail"
