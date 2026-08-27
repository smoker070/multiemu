#!/bin/bash
#
# Reports which host transports a guest image can actually talk to.
#
# Three milestones were shaped by this project building host-side transport for
# a driver the guest did not have: vsock (M4 HALs), virtio_net (M8/ADB) and 9p
# (M14/file sharing). Run this against a candidate image FIRST.
#
# It boots the image, because nothing cheaper is trustworthy. Grepping the
# kernel binary for driver names was tried and is worthless: `virtio_blk`
# appears zero times in a kernel that demonstrably drives a virtio disk, while
# `virtio_net` appears once in a kernel that has no network interface at all.
# Only the running guest knows.
#
# Usage: scripts/check-guest-drivers.sh <image-identifier> [disk-image]

set -u

IMAGE_ID="${1:-}"
if [ -z "$IMAGE_ID" ]; then
    echo "usage: $0 <image-identifier> [disk-image]" >&2
    exit 64
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STORE="$HOME/Library/Application Support/Multiemu/images/$IMAGE_ID"
KERNEL="$STORE/derived/kernel"
RAMDISK="$STORE/derived/ramdisk"
DISK="${2:-}"

for required in "$KERNEL" "$RAMDISK"; do
    if [ ! -f "$required" ]; then
        echo "missing $required — run: multiemu-image unpack $IMAGE_ID" >&2
        exit 66
    fi
done
if [ -z "$DISK" ] || [ ! -f "$DISK" ]; then
    echo "no composite disk given — run: multiemu-image composite $IMAGE_ID --out <path>" >&2
    exit 66
fi

QEMU="${QEMU:-/opt/homebrew/bin/qemu-system-aarch64}"
# Short, because sockaddr_un caps a socket path at 104 bytes and a project
# directory is easily longer than that on its own.
RUN="$(mktemp -d /tmp/mmdrv.XXXX)"
LOG="$RUN/console.log"
trap 'pkill -f "qemu-system-aarch64.*$RUN" 2>/dev/null; [ -n "${KEEP_LOG:-}" ] && cp "$RUN/console.log" "${KEEP_LOG}" 2>/dev/null; rm -rf "$RUN"' EXIT

# The sensors port is answered because a Cuttlefish guest will not finish
# booting without it; a non-Cuttlefish image simply ignores the port.
HVC=""
for i in $(seq 0 19); do
    if [ "$i" = 18 ]; then
        HVC="$HVC -chardev socket,id=hvc$i,path=$RUN/sensors.sock,server=on,wait=off"
    else
        HVC="$HVC -chardev null,id=hvc$i"
    fi
    HVC="$HVC -device virtconsole,bus=vser0.0,chardev=hvc$i"
done

"$QEMU" -machine virt -accel hvf -cpu host -smp 4 -m 4096 \
    -display none -nodefaults \
    -kernel "$KERNEL" -initrd "$RAMDISK" \
    -append "console=ttyAMA0 printk.devkmsg=on audit=0 panic=-1 cma=0 loop.max_part=7 init=/init \
androidboot.hardware=cutf_cvm androidboot.fstab_suffix=cf.f2fs.cts \
androidboot.slot_suffix=_a androidboot.selinux=permissive \
androidboot.force_normal_boot=1 androidboot.boot_devices=4010000000.pcie \
androidboot.verifiedbootstate=orange androidboot.vsock_lights_port=6800 \
androidboot.console=ttyAMA1 \
androidboot.hardware.egl=angle androidboot.hardware.vulkan=pastel \
androidboot.hardware.gralloc=minigbm androidboot.hardware.hwcomposer=drm \
androidboot.lcd_density=320 androidboot.opengles.version=196609 \
androidboot.vendor.apex.com.android.hardware.gatekeeper=com.android.hardware.gatekeeper.nonsecure.apex \
androidboot.vendor.apex.com.android.hardware.keymint=com.android.hardware.keymint.rust_nonsecure.apex \
androidboot.vendor.apex.com.android.hardware.graphics.composer=com.android.hardware.graphics.composer.drm_hwcomposer.apex \
androidboot.vendor.apex.com.google.emulated.camera.provider.hal=com.google.emulated.camera.provider.hal.apex \
${EXTRA_APPEND:-}" \
    -drive "file=$DISK,if=none,id=main,format=raw" \
    -device virtio-blk-pci,drive=main,addr=0x1 \
    -device virtio-gpu-pci,xres=1920,yres=1080 \
    -device virtio-rng-pci \
    -device virtio-serial-pci,id=vser0,max_ports=24 \
    $HVC \
    -netdev "user,id=net0" -device virtio-net-pci,netdev=net0 \
    -serial "file:$LOG" \
    -serial "unix:$RUN/shell.sock,server=on,wait=off" \
    -no-reboot >"$RUN/qemu.err" 2>&1 &

# Answer the sensors port, or a Cuttlefish guest stalls before userspace.
until [ -S "$RUN/sensors.sock" ]; do sleep 0.2; done
"$ROOT/.build/release/multiemu-guest-service" --sensors "$RUN/sensors.sock" >/dev/null 2>&1 &

echo "booting $IMAGE_ID…"
DEADLINE=$(( $(date +%s) + 180 ))
until grep -q "sys.boot_completed=1" "$LOG" 2>/dev/null; do
    # Keep checking that QEMU is still alive, not just that its socket exists.
    #
    # QEMU creates `-chardev socket,server=on` listeners BEFORE it validates
    # everything else, so a QEMU that dies on a later option leaves the socket
    # behind and this loop waits the full 180 s for a guest that was never
    # running. That reported "the guest did not boot" for what was actually an
    # immediate startup error, with the explanation sitting unread in qemu.err.
    if ! pgrep -f "qemu-system-aarch64.*$RUN" >/dev/null; then
        echo "QEMU exited during boot. Its own words:" >&2
        if [ -s "$RUN/qemu.err" ]; then
            sed 's/^/    /' "$RUN/qemu.err" >&2
        else
            echo "    (it printed nothing at all)" >&2
        fi
        echo "    (console captured so far: $(wc -c < "$LOG" 2>/dev/null || echo 0) bytes)" >&2
        exit 2
    fi
    if [ "$(date +%s)" -gt "$DEADLINE" ]; then
        echo "the guest did not boot within 180 s; inventory unavailable" >&2
        echo "QEMU is still running; the last of its console:" >&2
        tail -5 "$LOG" 2>/dev/null | sed 's/^/    /' >&2
        exit 2
    fi
    sleep 2
done
echo "booted."
echo

python3 - "$RUN/shell.sock" <<'PY'
import socket, sys, time

# The console echoes what is typed, so a marker that appears in the command
# matches against the echo. Build it from pieces the command never contains.
def ask(sock, command, quiet=1.5, cap=25):
    sock.sendall((command + "\n").encode())
    out, last = b"", time.time()
    end = time.time() + cap
    while time.time() < end:
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            if out and time.time() - last > quiet:
                break
            continue
        if not chunk:
            break
        out += chunk
        last = time.time()
    return out.decode("utf-8", "replace")

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(0.5)
s.connect(sys.argv[1])
s.sendall(b"\x03\n")
time.sleep(0.8)
try:
    while s.recv(65536):
        pass
except socket.timeout:
    pass

checks = [
    # 9p and virtiofs are separate answers. Lumping them together reported
    # "yes" for an image that has virtiofs and no 9p at all — which is the
    # image already known to fail.
    ("9p filesystem (needed for the host's virtio-9p share)",
     "grep -cw 9p /proc/filesystems"),
    ("virtiofs filesystem (host has no virtio-fs device to pair with)",
     "grep -cw virtiofs /proc/filesystems"),
    # Counting entries in /sys/class/net is not a network check: dummy0, ifb0,
    # tunl0 and gre0 are all there on a guest with no usable interface at all.
    # What matters is an interface actually backed by a virtio device.
    ("network interface backed by virtio (needed for ADB)",
     "ls -l /sys/class/net/*/device 2>/dev/null | grep -c virtio"),
    # Modules live in the dlkm partitions, NOT /lib/modules — which is empty on
    # this image, and searching only it reported "no 9p" for a guest that ships
    # two 9p modules.
    #
    # And a missing module proves nothing on its own: virtio_net has no module
    # here either, yet virtio networking works, because it is built into the
    # kernel. Treat these as detail for the filesystem answers above, never as
    # the answer.
    ("9p filesystem module (9p.ko / v9fs.ko — the mountable half)",
     "find /system_dlkm /vendor_dlkm /system/lib/modules -name '9p.ko' -o -name 'v9fs.ko' 2>/dev/null | wc -l"),
    ("9p virtio transport module (9pnet_virtio.ko)",
     "find /system_dlkm /vendor_dlkm /system/lib/modules -name '9pnet_virtio.ko' 2>/dev/null | wc -l"),
    # /proc/net/protocols does not name it; the loaded transport module does.
    ("vsock transport loaded",
     "grep -c vsock /proc/modules"),
]


print("| Capability | Present |")
print("| --- | --- |")
for label, command in checks:
    reply = ask(s, "printf 'R%s:' X; " + command)
    count = None
    for line in reply.splitlines():
        if line.startswith("RX:"):
            tail = line[3:].strip()
            if tail.isdigit():
                count = int(tail)
    if count is None:
        for line in reversed(reply.splitlines()):
            token = line.strip()
            if token.isdigit():
                count = int(token)
                break
    mark = "unknown" if count is None else ("**yes**" if count > 0 else "no")
    print(f"| {label} | {mark} |")
s.close()
PY

echo
echo "What each answer means:"
echo "  9p filesystem          -> M14 file sharing works; the host offers virtio-9p"
echo "  virtio-backed interface-> the driver ADB needs is present (routing is separate)"
echo "  virtiofs alone         -> NOT usable: QEMU on macOS has no virtio-fs device"
echo
echo "For reference, the image measured on 2026-08-23 answers: 9p no, virtiofs"
echo "yes, virtio interface YES. A candidate that also lacks 9p buys nothing for"
echo "M14."
