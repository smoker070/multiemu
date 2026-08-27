#!/bin/bash
#
# Answers two questions about audio, in one boot:
#
#   1. Can this guest see a sound card this QEMU can offer?
#   2. If it can, does anything the guest plays reach the host?
#
# Milestone 11 was deferred on a fixture that predates Android, so the reasons
# recorded then ("no HDA driver", "no /dev/snd") describe a guest this project
# no longer runs. This attaches every audio device QEMU 11.1.0 on macOS builds
# — intel-hda, AC97 and USB audio; there is no virtio-sound in this build — and
# asks the running guest what it enumerated.
#
# The host backend is `wav`, which writes what the guest plays to a file. That
# makes question 2 answerable without any host audio permission and without a
# human listening: a silent or absent file is a negative result, and a file with
# non-zero samples is a positive one.
#
# Usage: scripts/check-guest-audio.sh <image-identifier> <disk-image>

set -u

IMAGE_ID="${1:-}"
DISK="${2:-}"
if [ -z "$IMAGE_ID" ] || [ -z "$DISK" ]; then
    echo "usage: $0 <image-identifier> <disk-image>" >&2
    exit 64
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STORE="$HOME/Library/Application Support/Multiemu/images/$IMAGE_ID"
KERNEL="$STORE/derived/kernel"
RAMDISK="$STORE/derived/ramdisk"
QEMU="${QEMU:-/opt/homebrew/bin/qemu-system-aarch64}"
ADB_PORT="${ADB_PORT:-15556}"
OUT_WAV="${OUT_WAV:-/tmp/multiemu-guest-audio.wav}"

for required in "$KERNEL" "$RAMDISK" "$DISK"; do
    [ -f "$required" ] || { echo "missing $required" >&2; exit 66; }
done

RUN="$(mktemp -d /tmp/mmaud.XXXX)"
LOG="$RUN/console.log"
cleanup() {
    pkill -f "qemu-system-aarch64.*$RUN" 2>/dev/null
    /bin/rm -rf "$RUN"
}
trap cleanup EXIT

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
androidboot.vendor.apex.com.google.emulated.camera.provider.hal=com.google.emulated.camera.provider.hal.apex" \
    -drive "file=$DISK,if=none,id=main,format=raw" \
    -device virtio-blk-pci,drive=main,addr=0x1 \
    -device virtio-gpu-pci,xres=1920,yres=1080 \
    -device virtio-rng-pci \
    -device virtio-serial-pci,id=vser0,max_ports=24 \
    $HVC \
    -audiodev "wav,id=snd0,path=$RUN/out.wav" \
    -device intel-hda -device hda-output,audiodev=snd0 \
    -device AC97,audiodev=snd0 \
    -device qemu-xhci,id=xhci -device usb-audio,bus=xhci.0,audiodev=snd0 \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$ADB_PORT-:5555" \
    -device virtio-net-pci,netdev=net0 \
    -serial "file:$LOG" \
    -serial "unix:$RUN/shell.sock,server=on,wait=off" \
    -no-reboot >"$RUN/qemu.err" 2>&1 &

until [ -S "$RUN/sensors.sock" ]; do
    sleep 0.2
    if ! pgrep -f "qemu-system-aarch64.*$RUN" >/dev/null; then
        echo "QEMU exited before it created the sensors port:" >&2
        cat "$RUN/qemu.err" >&2
        exit 2
    fi
done
"$ROOT/.build/release/multiemu-guest-service" --sensors "$RUN/sensors.sock" >/dev/null 2>&1 &

echo "booting $IMAGE_ID with every audio device this QEMU offers…"
DEADLINE=$(( $(date +%s) + 240 ))
until grep -q "sys.boot_completed=1" "$LOG" 2>/dev/null; do
    if [ "$(date +%s)" -gt "$DEADLINE" ]; then
        echo "the guest did not boot within 240 s" >&2
        tail -20 "$LOG" >&2
        exit 2
    fi
    sleep 2
done
echo "booted."
echo

python3 - "$RUN/shell.sock" <<'PY'
import socket, sys, time

def ask(sock, command, quiet=1.5, cap=30):
    sock.sendall((command + "\n").encode())
    out, last, end = b"", time.time(), time.time() + cap
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

questions = [
    ("ALSA cards the kernel registered", "cat /proc/asound/cards 2>&1"),
    ("PCM device nodes", "ls /dev/snd 2>&1"),
    ("audio HAL implementations shipped on the image",
     "ls /vendor/lib64/hw/audio.* /apex/com.android.hardware.audio/lib64/*.so 2>/dev/null | head -20"),
    ("a tool that writes straight to ALSA",
     "which tinyplay tinymix tinypcminfo 2>/dev/null"),
    ("does AudioFlinger know about a USB device",
     "dumpsys media.audio_flinger 2>/dev/null | grep -ic usb"),
    ("output devices the policy engine reports",
     "dumpsys audio 2>/dev/null | grep -iE 'device.*out|Devices:' | head -6"),
]
for label, command in questions:
    print(f"--- {label} ---")
    reply = ask(s, command)
    for line in reply.splitlines()[1:]:
        text = line.strip()
        if text and not text.startswith(command[:20]) and text != "console:/ $":
            print("   ", text)
    print()

# Enable ADB so the framework path can be driven from outside.
for command in [
    "su 0 ip link set buried_eth0 up",
    "su 0 ip addr add 10.0.2.15/24 dev buried_eth0",
    "su 0 ip route add 10.0.2.0/24 dev buried_eth0 table local_network",
    "su 0 setprop service.adb.tcp.port 5555",
    "su 0 stop adbd",
    "su 0 start adbd",
]:
    ask(s, command, quiet=0.8, cap=8)
s.close()
print("ADB enabled for the playback attempt.")
PY

echo
echo "--- playback attempt ---"
ADB="$ROOT/.build/debug/multiemu-adb"
if [ ! -x "$ADB" ]; then ADB="$ROOT/.build/release/multiemu-adb"; fi
sleep 3

if "$ADB" --port "$ADB_PORT" info >/dev/null 2>&1; then
    # A tone the guest can play. Generated here so nothing has to be downloaded
    # and so the samples are known: silence in the capture then means the audio
    # did not travel, not that the source was silent.
    python3 - "$RUN/tone.wav" <<'PY'
import math, struct, sys, wave
with wave.open(sys.argv[1], "w") as out:
    out.setnchannels(2)
    out.setsampwidth(2)
    # 48 kHz, because the guest's USB card refuses anything lower:
    # `Sample rate is 44100Hz, device only supports >= 48000Hz`.
    out.setframerate(48000)
    frames = bytearray()
    for index in range(48000 * 3):
        value = int(20000 * math.sin(2 * math.pi * 440 * index / 48000))
        frames += struct.pack("<hh", value, value)
    out.writeframes(bytes(frames))
PY
    "$ADB" --port "$ADB_PORT" push "$RUN/tone.wav" /data/local/tmp/tone.wav >/dev/null 2>&1

    echo "  who owns the PCM node:"
    "$ADB" --port "$ADB_PORT" shell "ls -l /dev/snd/ 2>&1" | sed 's/^/    /'

    # Two attempts, because they answer different questions. As `shell` it
    # tests what an unprivileged caller can do; as root it tests whether the
    # device works at all. Only the second distinguishes "the guest cannot
    # reach this card" from "this caller may not".
    echo "  playing a 3 s 440 Hz tone as shell…"
    "$ADB" --port "$ADB_PORT" shell "tinyplay /data/local/tmp/tone.wav 2>&1 | head -3" | sed 's/^/    /' || true
    sleep 4
    echo "  playing it again as root…"
    "$ADB" --port "$ADB_PORT" shell "su 0 tinyplay /data/local/tmp/tone.wav 2>&1 | head -3" | sed 's/^/    /' || true
    sleep 4
else
    echo "  ADB did not come up; the playback half was not attempted." >&2
fi

echo
echo "--- what reached the host ---"
# QEMU's wav backend writes the RIFF sizes when it closes the file, so the
# guest has to be stopped before the capture can be read as a WAV. Reading it
# while QEMU still held it reported "not a WAVE file" for a capture that was
# perfectly good.
pkill -f "qemu-system-aarch64.*$RUN" 2>/dev/null
sleep 2

if [ -f "$RUN/out.wav" ]; then
    SIZE=$(/bin/ls -l "$RUN/out.wav" | awk '{print $5}')
    /bin/cp "$RUN/out.wav" "$OUT_WAV" 2>/dev/null
    echo "    QEMU wrote $SIZE bytes to $OUT_WAV"
    # A WAV header alone is 44 bytes. Anything more means samples arrived.
    python3 - "$OUT_WAV" <<'PY'
import sys, wave
try:
    with wave.open(sys.argv[1]) as source:
        frames = source.getnframes()
        data = source.readframes(min(frames, 44100))
        peak = max((abs(int.from_bytes(data[i:i+2], "little", signed=True))
                    for i in range(0, len(data) - 1, 2)), default=0)
        print(f"    {frames} frames at {source.getframerate()} Hz, peak amplitude {peak}")
        print("    VERDICT:", "audio reached the host" if peak > 0
              else "the file is silent — nothing was played through this device")
except Exception as error:
    print(f"    could not read it as a WAV: {error}")
PY
else
    echo "    QEMU wrote no file at all — nothing ever opened the audio device."
fi
