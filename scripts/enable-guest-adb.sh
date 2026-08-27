#!/bin/bash
#
# Makes a running Android guest reachable by ADB over the host's loopback
# forward, and proves it by completing an ADB handshake.
#
# Four things have to be true, and three of them are not true by default on a
# Cuttlefish image:
#
#   1. The ethernet exists. It does — `virtio_net` is built into the kernel —
#      but Cuttlefish names it `buried_eth0` and leaves it DOWN, because
#      Android's connectivity stack deliberately does not manage it.
#   2. It has the address QEMU's user-mode network expects (10.0.2.15/24).
#   3. **A route in the `local_network` table.** This is the one that is easy to
#      miss: Android uses policy routing, and its rule set contains no
#      `lookup main` at all — it ends in `32000: from all unreachable`. The
#      on-link route the kernel adds with the address lands in `main` and is
#      therefore never consulted, so the SYN arrives and no SYN-ACK is ever
#      routed back. The symptom is a connection that hangs with adbd listening
#      and the interface counting the inbound packet.
#   4. adbd told to serve TCP. It defaults to vsock on this image.
#
# This drives the guest's console shell, which is a **bring-up channel, not a
# product transport**: it is a root shell inside the guest. The emulator should
# perform this setup over a channel it owns rather than by typing at a shell.
#
# Usage: scripts/enable-guest-adb.sh <console-socket> [host-adb-port]

set -u

CONSOLE="${1:-}"
PORT="${2:-15555}"
if [ -z "$CONSOLE" ] || [ ! -S "$CONSOLE" ]; then
    echo "usage: $0 <console-socket> [host-adb-port]" >&2
    echo "  the guest must be running with androidboot.console on that socket" >&2
    exit 64
fi

python3 - "$CONSOLE" "$PORT" <<'PY'
import socket, struct, sys, time

console_path, port = sys.argv[1], int(sys.argv[2])

def shell(sock, command, quiet=1.5, cap=25):
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

console = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
console.settimeout(0.5)
console.connect(console_path)
console.sendall(b"\x03\n")
time.sleep(0.8)
try:
    while console.recv(65536):
        pass
except socket.timeout:
    pass

steps = [
    ("bringing the interface up", "su 0 ip link set buried_eth0 up"),
    ("addressing it", "su 0 ip addr add 10.0.2.15/24 dev buried_eth0"),
    # The step that actually fixes the hang.
    ("routing replies via local_network",
     "su 0 ip route add 10.0.2.0/24 dev buried_eth0 table local_network"),
    ("switching adbd to TCP",
     "su 0 setprop service.adb.tcp.port 5555; su 0 stop adbd; su 0 start adbd"),
]
for label, command in steps:
    print(f"  {label}…")
    shell(console, command)
console.close()
time.sleep(2)

# Prove it, rather than assume it: complete a real ADB handshake.
def pack(command, arg0, arg1, payload=b""):
    cmd, = struct.unpack("<I", command)
    return struct.pack("<IIIIII", cmd, arg0, arg1, len(payload),
                       sum(payload) & 0xFFFFFFFF, cmd ^ 0xFFFFFFFF) + payload

try:
    adb = socket.create_connection(("127.0.0.1", port), timeout=10)
except OSError as error:
    print(f"could not reach 127.0.0.1:{port}: {error}", file=sys.stderr)
    sys.exit(2)

adb.settimeout(10)
adb.sendall(pack(b"CNXN", 0x01000001, 256 * 1024, b"host::multiemu\x00"))

def recv_exact(sock, count):
    # The header and the payload need not arrive in one segment. Reading once
    # printed an empty banner, which read like a failure and was not.
    buf = b""
    while len(buf) < count:
        chunk = sock.recv(count - len(buf))
        if not chunk:
            raise ConnectionError("adbd closed the connection")
        buf += chunk
    return buf

try:
    header = recv_exact(adb, 24)
    cmd, _, _, length, _, _ = struct.unpack("<IIIIII", header)
    payload = recv_exact(adb, length) if length else b""
except (socket.timeout, ConnectionError):
    print("adbd did not answer — the routing step probably did not take",
          file=sys.stderr)
    sys.exit(2)
finally:
    adb.close()

command = struct.pack("<I", cmd).decode("ascii", "replace")
banner = payload.split(b";")[0].decode("utf-8", "replace")
print()
print(f"ADB reachable on 127.0.0.1:{port} — {command}, {banner}")
PY
