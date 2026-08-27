#!/bin/bash
# Builds and runs multiemu-probe, saving a JSON host report under reports/.
# The JSON report is the required context block for every performance report.
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p reports

echo "Building (release)..."
swift build -c release --product multiemu-probe

stamp=$(date +%Y%m%d-%H%M%S)
json="reports/host-${stamp}.json"

set +e
.build/release/multiemu-probe --format text
status=$?
set -e

.build/release/multiemu-probe --format json --output "$json" >/dev/null
echo
echo "JSON report: $json"

case "$status" in
  0) echo "Host is usable." ;;
  2) echo "Blocking host problems were reported above." ;;
  *) echo "Probe exited with status $status." ;;
esac
exit "$status"
