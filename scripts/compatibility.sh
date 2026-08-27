#!/bin/bash
# Runs every claim the compatibility matrix makes and regenerates the matrix
# from what happened.
#
# docs/COMPATIBILITY-MATRIX.md is an OUTPUT. Editing it by hand puts a claim in
# front of readers that nothing checked, which is the situation Milestone 20
# removed.
#
# Usage:
#   scripts/compatibility.sh              # suites and live-guest spikes
#   scripts/compatibility.sh --no-spikes  # suites only; faster, less covered
set -euo pipefail

cd "$(dirname "$0")/.."

kernel="vendor/test-kernels/arm64/vmlinuz-lts"
initrd="vendor/test-kernels/arm64/initramfs-lts"

echo "Building..."
swift build -c release

arguments=(--run --output docs/COMPATIBILITY-MATRIX.md --json reports/compatibility-latest.json)

if [ "${1:-}" = "--no-spikes" ]; then
  arguments+=(--no-spikes)
  echo "Running suites only. Claims backed by a live guest will read as untested."
elif [ -f "$kernel" ]; then
  arguments+=(--kernel "$kernel" --initrd "$initrd")
else
  echo "No guest kernel at $kernel."
  echo "Fetch one with scripts/fetch-test-kernel.sh, or pass --no-spikes."
  echo "Continuing without it; live-guest claims will read as untested."
fi

mkdir -p reports
set +e
.build/release/multiemu-compat "${arguments[@]}"
status=$?
set -e

echo
case "$status" in
  0) echo "Every claim that could be checked passed." ;;
  *) echo "At least one claim failed. The matrix records which." ;;
esac
exit "$status"
