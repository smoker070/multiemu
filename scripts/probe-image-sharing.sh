#!/bin/bash
# Probes whether the installed QEMU lets two processes hold one image at once.
#
# Multi-instance depends on read-only guest images being SHARED rather than
# copied, and that rests on QEMU's advisory image locking. This is a property of
# the QEMU build, not of our code, so it is re-checked rather than assumed --
# a version bump could change it.
#
# The writable+writable case is the CONTROL. Without it, "both processes
# started" could simply mean locking was disabled, which would make the
# read-only result meaningless.
#
# Usage: scripts/probe-image-sharing.sh
set -euo pipefail

cd "$(dirname "$0")/.."

qemu=$(command -v qemu-system-aarch64 || true)
img_tool=$(command -v qemu-img || true)
if [ -z "$qemu" ] || [ -z "$img_tool" ]; then
  echo "qemu-system-aarch64 and qemu-img are required (development: brew install qemu)" >&2
  exit 65
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
image="$work/shared.img"
"$img_tool" create -f raw "$image" 64M >/dev/null

echo "QEMU:  $("$qemu" --version | head -1)"
echo "Image: $image"
echo

# Starts a paused VM holding the image, so only the image open is under test.
start() {
  "$qemu" -machine virt -accel hvf -cpu host -m 256 \
    -display none -nodefaults -S \
    -drive "if=none,id=d0,file=$image,format=raw${1:+,$1}" \
    -device virtio-blk-pci,drive=d0 \
    >"$2" 2>&1 &
  echo $!
}

alive_after_settle() {
  # QEMU either fails the open almost immediately or stays up; give it a moment.
  /bin/sleep 2
  kill -0 "$1" 2>/dev/null
}

run_case() {
  local name="$1" first="$2" second="$3"
  local out_a="$work/a.log" out_b="$work/b.log"

  local pid_a; pid_a=$(start "$first" "$out_a")
  if ! alive_after_settle "$pid_a"; then
    echo "$name: first process failed to start:"; sed 's/^/    /' "$out_a"; return
  fi
  local pid_b; pid_b=$(start "$second" "$out_b")
  local verdict="BOTH RUNNING"
  alive_after_settle "$pid_b" || verdict="SECOND REFUSED"

  printf '%s\n  first : %s\n  second: %s\n  -> %s\n' \
    "$name" "${first:-writable}" "${second:-writable}" "$verdict"
  [ "$verdict" = "BOTH RUNNING" ] || sed 's/^/     /' "$out_b"
  echo

  kill "$pid_a" "$pid_b" 2>/dev/null || true
  wait "$pid_a" "$pid_b" 2>/dev/null || true
}

run_case "A. read-only + read-only  (what sharing an image needs)" "readonly=on" "readonly=on"
run_case "B. writable + writable    (CONTROL: proves locking is active)" "" ""
run_case "C. writable + read-only   (a writer must not be shadowed)" "" "readonly=on"
run_case "D. read-only + writable   (reader first, then writer)" "readonly=on" ""

cat <<'NOTE'
Expected on a correctly locking QEMU: A shares, B/C/D are all refused.

That combination is what makes read-only sharing safe: it works, and it only
works while nobody opens the image writable. See docs/VERIFY.md,
QEMU-SHARES-READ-ONLY-IMAGES.
NOTE
