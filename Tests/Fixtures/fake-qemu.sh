#!/bin/bash
# A stand-in for qemu-system-* that replays a recorded guest console.
#
# Lets the whole Milestone 2 boot harness — process spawn, line buffering,
# milestone recognition, timing, watchdog and termination handling — be verified
# without QEMU installed, and lets CI regression-test boot detection on machines
# without hardware virtualization.
#
#   multiemu-boot --qemu Tests/Fixtures/fake-qemu.sh --kernel <any file> \
#                 --extra --multiemu-scenario --extra panic
#
# Scenarios: success (default), panic, hang.
#
# The scenario is read from argv, not the environment, because QEMUProcess
# deliberately gives its child a minimal environment (PATH only) so that a
# developer's shell cannot alter backend behaviour. Every other argument is
# accepted and ignored.
set -uo pipefail

scenario="success"
previous=""
for argument in "$@"; do
  if [ "$previous" = "--multiemu-scenario" ]; then scenario="$argument"; fi
  previous="$argument"
done

echo "QEMU stand-in: $# arguments, scenario=$scenario" >&2

step() { printf '%s\n' "$1"; sleep "0.05"; }

case "$scenario" in
panic)
  step "[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x611f0000]"
  step "[    0.000000] Linux version 6.6.0 (multiemu@fixture)"
  step "[    1.100000] Freeing initrd memory: 8192K"
  step "[    2.400000] Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)"
  # -no-reboot means a real QEMU exits here too.
  exit 1
  ;;
hang)
  step "[    0.000000] pci 0000:00:01.0: BAR 4: assigned [mem 0x10000000-0x10003fff]"
  step "[    0.100000] usb 1-1: new high-speed USB device number 2"
  sleep 3600
  ;;
*)
  step "[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x611f0000]"
  step "[    0.000000] Linux version 6.6.0 (multiemu@fixture) #1 SMP PREEMPT"
  step "[    0.000000] Machine model: linux,dummy-virt"
  step "[    0.412000] virtio_blk virtio1: [vda] 65536 512-byte logical blocks"
  step "[    0.980000] Freeing initrd memory: 8192K"
  step "[    1.240000] Run /init as init process"
  step "Welcome to Alpine Linux 3.21"
  # A real QEMU keeps running here until terminated, so the harness's
  # terminate-on-terminal-milestone path is exercised.
  sleep 3600
  ;;
esac
