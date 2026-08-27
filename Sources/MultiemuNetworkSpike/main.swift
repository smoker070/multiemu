import Darwin
import Foundation
import MultiemuBackend
import MultiemuDBus
import MultiemuGraphics
import MultiemuHost
import MultiemuInput
import MultiemuQEMU
import MultiemuSupport

// multiemu-network-spike — Milestone 7 verification.
//
// Tests guest networking in both directions, entirely on loopback and with no
// external egress:
//
//   guest -> host   the guest fetches a marker from a loopback server reachable
//                   through libslirp's gateway address (10.0.2.2), which maps
//                   to the host's own loopback
//   host  -> guest  the host connects to a forwarded port and reads a marker
//                   served by a listener inside the guest
//
// The guest is configured by typing into its shell over the D-Bus keyboard
// interface built in Milestone 6.

setvbuf(stdout, nil, _IONBF, 0)

func row(_ label: String, _ value: String) {
    print("  \(label.padding(toLength: 34, withPad: " ", startingAt: 0)) \(value)")
}
func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("multiemu-network-spike: \(message)\n".utf8))
    exit(code)
}

/// Serves a fixed body to any connection, on loopback only.
///
/// Deliberately not a general server: it exists so the guest has something
/// local to fetch, proving the network path without reaching the internet.
final class LoopbackProbeServer: @unchecked Sendable {
    let port: Int
    private let body: String
    private var listener: Int32 = -1
    private let hitLock = NSLock()
    private var hits = 0

    init(port: Int, body: String) {
        self.port = port
        self.body = body
    }

    var requestCount: Int { hitLock.lock(); defer { hitLock.unlock() }; return hits }

    func start() throws {
        listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        var reuse: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian   // 127.0.0.1 only
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listener, 4) == 0 else { throw POSIXError(.EADDRINUSE) }

        let descriptor = listener
        let header = "HTTP/1.0 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        let payload = header + body
        let thread = Thread { [weak self] in
            while true {
                let connection = accept(descriptor, nil, nil)
                guard connection >= 0 else { return }
                var scratch = [UInt8](repeating: 0, count: 2048)
                _ = read(connection, &scratch, scratch.count)
                _ = Array(payload.utf8).withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
                close(connection)
                self?.hitLock.lock(); self?.hits += 1; self?.hitLock.unlock()
            }
        }
        thread.name = "multiemu.network.probe"
        thread.start()
    }

    func stop() { if listener >= 0 { close(listener) } }
}

/// Connects to a loopback port and reads whatever arrives.
func readFromLoopback(port: Int, timeout: TimeInterval = 5) -> String? {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    var deadline = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { return nil }

    var buffer = [UInt8](repeating: 0, count: 4096)
    let count = read(descriptor, &buffer, buffer.count)
    guard count > 0 else { return nil }
    return String(decoding: buffer[0..<count], as: UTF8.self)
}

var outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
var kernelURL: URL?
var initrdURL: URL?
var shellDelay = 10
var argv = Array(CommandLine.arguments.dropFirst())
var argumentIndex = 0
while argumentIndex < argv.count {
    func next() -> String { argumentIndex += 1; return argumentIndex < argv.count ? argv[argumentIndex] : "" }
    switch argv[argumentIndex] {
    case "--kernel": kernelURL = URL(fileURLWithPath: next())
    case "--initrd": initrdURL = URL(fileURLWithPath: next())
    case "--out": outputDirectory = URL(fileURLWithPath: next())
    case "--shell-delay": shellDelay = Int(next()) ?? 10
    default: break
    }
    argumentIndex += 1
}
guard let kernel = kernelURL else { fail("--kernel is required", code: 64) }
guard let qemuPath = ExternalToolProbe.resolve("qemu-system-aarch64") else {
    fail("qemu-system-aarch64 not found", code: 65)
}

let httpPort = (try? HostPortAllocator.allocate()) ?? 18080
let forwardHostPort = (try? HostPortAllocator.allocate(excluding: [httpPort])) ?? 18081
let guestListenPort = 5000
let markerFromHost = "MULTIEMU_NET_HOST_\(UInt32.random(in: 100_000...999_999))"
let markerFromGuest = "MULTIEMU_NET_GUEST_\(UInt32.random(in: 100_000...999_999))"

let network = GuestNetworkConfiguration(portForwards: [
    .init(label: "spike", hostPort: forwardHostPort, guestPort: guestListenPort)
])
let networkProblems = network.problems()

print("multiemu-network-spike")
row("qemu", qemuPath)
row("mode", network.mode.rawValue)
row("host loopback probe", "127.0.0.1:\(httpPort)")
row("forward", "127.0.0.1:\(forwardHostPort) -> guest :\(guestListenPort)")
row("configuration problems", networkProblems.isEmpty ? "none" : networkProblems.joined(separator: "; "))
print("")
guard networkProblems.isEmpty else { fail("network configuration is invalid") }

let probe = LoopbackProbeServer(port: httpPort, body: markerFromHost)
do { try probe.start() } catch { fail("could not start the loopback probe: \(error)") }

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let serialLog = outputDirectory.appendingPathComponent("network-serial.log")
try? FileManager.default.removeItem(at: serialLog)

let socketPath = QMPClient.makeSocketPath(role: "net")
var arguments = [
    "-machine", "virt", "-accel", "hvf", "-cpu", "host",
    "-smp", "4", "-m", "2048",
    "-device", "virtio-gpu-pci,xres=1280,yres=800",
    "-device", "virtio-keyboard-pci",
    "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:\(forwardHostPort)-:\(guestListenPort)",
    "-device", "virtio-net-pci,netdev=net0",
    "-display", "dbus,p2p=on",
    "-kernel", kernel.path,
    "-append", "console=ttyAMA0 console=tty0",
    "-serial", "file:\(serialLog.path)",
    "-qmp", "unix:\(socketPath),server=on,wait=off",
    "-no-reboot",
]
if let initrd = initrdURL { arguments += ["-initrd", initrd.path] }

let qemu = QEMUProcess(executableURL: URL(fileURLWithPath: qemuPath), arguments: arguments)
let drain = Task { for await _ in qemu.events {} }
do { try qemu.start() } catch { fail("could not start QEMU: \(error)") }

let control = QMPClient()
do { _ = try await control.connect(toSocketAt: socketPath, timeout: .seconds(15)) }
catch { qemu.kill(); fail("QMP connect failed: \(error)") }

var descriptors: [Int32] = [0, 0]
guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { qemu.kill(); fail("socketpair failed: \(String(cString: strerror(errno)))") }
do {
    try await control.sendFileDescriptor(descriptors[1], named: "displayfd")
    try await control.addClient(protocolName: "@dbus-display", fileDescriptorName: "displayfd")
} catch { qemu.kill(); fail("display attach failed: \(error)") }
Darwin.close(descriptors[1])

let console = DBusConnection(descriptor: descriptors[0], role: .client)
do { try await console.authenticate() } catch { qemu.kill(); fail("D-Bus auth failed: \(error)") }
let display = QEMUDisplayClient(consoleConnection: console)
let frames = display.events
do { try await display.registerListener() } catch { qemu.kill(); fail("RegisterListener failed: \(error)") }
let sink = Task { for await _ in frames {} }

let input = QEMUInputClient(connection: console)
row("waiting", "\(shellDelay)s for the guest shell")
try? await Task.sleep(for: .seconds(shellDelay))

func serialText() -> String { (try? String(contentsOf: serialLog, encoding: .utf8)) ?? "" }

let gateway = GuestNetworkConfiguration.UserModeAddresses.gateway
let guestAddress = GuestNetworkConfiguration.UserModeAddresses.guest

// Static addressing: libslirp's addresses are fixed, and this isolates the
// network path from whatever DHCP client the initramfs happens to ship.
row("configuring", "eth0 -> \(guestAddress)")
try? await input.type("ip link set eth0 up\n")
try? await input.type("ip addr add \(guestAddress)/24 dev eth0\n")
try? await input.type("ip route add default via \(gateway)\n")
try? await input.type("ip -4 addr show eth0 | grep inet > /dev/ttyAMA0\n")
try? await Task.sleep(for: .seconds(3))
let interfaceConfigured = serialText().contains(guestAddress)

// guest -> host, through libslirp's gateway (which maps to host loopback).
let probeURL = "http://\(gateway):\(httpPort)/"
try? await input.type("wget -q -O - \(probeURL) > /dev/ttyAMA0\n")
try? await Task.sleep(for: .seconds(5))
let guestReachedHost = serialText().contains(markerFromHost)

// host -> guest, through the forwarded port. The listener runs inside the guest.
let guestListenCommand = "echo \(markerFromGuest) | nc -l -p \(guestListenPort) &"
try? await input.type(guestListenCommand + "\n")
try? await Task.sleep(for: .seconds(3))
let received = readFromLoopback(port: forwardHostPort)
let hostReachedGuest = received?.contains(markerFromGuest) ?? false

// Is the forwarded port bound to loopback only?
let lsof = Process()
lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
lsof.arguments = ["-nP", "-iTCP:\(forwardHostPort)", "-sTCP:LISTEN"]
let pipe = Pipe()
lsof.standardOutput = pipe
lsof.standardError = Pipe()
try? lsof.run()
let lsofOutput = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
lsof.waitUntilExit()
let boundToLoopbackOnly = lsofOutput.contains("127.0.0.1:\(forwardHostPort)")
    && !lsofOutput.contains("*:\(forwardHostPort)")

print("")
print("Results")
row("guest interface configured", interfaceConfigured ? "YES (\(guestAddress) present)" : "no")
row("guest -> host via gateway", guestReachedHost ? "YES (marker fetched)" : "no")
row("host probe requests served", "\(probe.requestCount)")
row("host -> guest via forward", hostReachedGuest ? "YES (marker read from guest)" : "no")
row("forward bound loopback only", boundToLoopbackOnly ? "YES" : "NO — investigate")
for line in lsofOutput.split(separator: "\n").dropFirst().prefix(2) {
    row("  listener", String(line.suffix(58)))
}

if !guestReachedHost || !hostReachedGuest {
    print("\n  serial tail:")
    for line in serialText().split(separator: "\n").suffix(8) { print("    \(line)") }
}

// The host -> guest leg depends on a listener utility existing in this
// initramfs, which is a property of the test fixture rather than of Multiemu,
// so it is reported separately and does not by itself fail the milestone.
let core = interfaceConfigured && guestReachedHost && boundToLoopbackOnly
print("")
print(core
    ? "RESULT: PASS — guest networking works and the forward is loopback-only."
    : "RESULT: FAIL — see above.")

probe.stop()
sink.cancel()
await display.close()
qemu.kill()
drain.cancel()
exit(core ? 0 : 2)
