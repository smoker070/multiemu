import CoreGraphics
import Darwin
import Foundation
import MultiemuBackend
import MultiemuDBus
import MultiemuGraphics
import MultiemuHost
import MultiemuInput
import MultiemuQEMU
import MultiemuSupport

// multiemu-input-spike — Milestone 6 verification.
//
// Proves input reaches the guest, textually rather than by eye: the guest boots
// with its console on the virtio-gpu framebuffer, Multiemu types a shell command
// through QEMU's D-Bus keyboard interface, and the command writes a marker to a
// serial port captured to a file. If the marker appears, the keystrokes arrived
// *and* the key codes were right.

setvbuf(stdout, nil, _IONBF, 0)

let marker = "MULTIEMU_INPUT_OK_\(UInt32.random(in: 100_000...999_999))"
var outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
var shellDelaySeconds = 10
var argv = Array(CommandLine.arguments.dropFirst())
var index = 0
var kernelURL: URL?
var initrdURL: URL?
while index < argv.count {
    func next() -> String { index += 1; return index < argv.count ? argv[index] : "" }
    switch argv[index] {
    case "--kernel": kernelURL = URL(fileURLWithPath: next())
    case "--initrd": initrdURL = URL(fileURLWithPath: next())
    case "--out": outputDirectory = URL(fileURLWithPath: next())
    case "--shell-delay": shellDelaySeconds = Int(next()) ?? 10
    default: break
    }
    index += 1
}

func row(_ label: String, _ value: String) {
    print("  \(label.padding(toLength: 32, withPad: " ", startingAt: 0)) \(value)")
}
func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("multiemu-input-spike: \(message)\n".utf8))
    exit(code)
}

guard let kernel = kernelURL else { fail("--kernel is required", code: 64) }
guard let qemuPath = ExternalToolProbe.resolve("qemu-system-aarch64") else {
    fail("qemu-system-aarch64 not found", code: 65)
}
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let serialLog = outputDirectory.appendingPathComponent("input-serial.log")
try? FileManager.default.removeItem(at: serialLog)

let socketPath = QMPClient.makeSocketPath(role: "input")
var arguments = [
    "-machine", "virt", "-accel", "hvf", "-cpu", "host",
    "-smp", "4", "-m", "2048",
    "-device", "virtio-gpu-pci,xres=1280,yres=800",
    "-device", "virtio-keyboard-pci",
    "-device", "virtio-tablet-pci",
    "-display", "dbus,p2p=on",
    "-kernel", kernel.path,
    // Console order matters: the LAST console= becomes /dev/console, so putting
    // tty0 last puts the shell on the framebuffer where keyboard input lands,
    // while ttyAMA0 remains available as a device to write the marker to.
    "-append", "console=ttyAMA0 console=tty0",
    "-serial", "file:\(serialLog.path)",
    "-qmp", "unix:\(socketPath),server=on,wait=off",
    "-no-reboot",
]
if let initrd = initrdURL { arguments += ["-initrd", initrd.path] }

print("multiemu-input-spike")
row("qemu", qemuPath)
row("input devices", "virtio-keyboard-pci, virtio-tablet-pci")
row("marker", marker)
print("")

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
row("D-Bus", "attached")

// A listener keeps the console live and lets us capture what the guest shows.
let display = QEMUDisplayClient(consoleConnection: console)
let frames = display.events
do { try await display.registerListener() } catch { qemu.kill(); fail("RegisterListener failed: \(error)") }

let latestFrame = FrameBox()
final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: GuestFrame?
    func store(_ newFrame: GuestFrame) { lock.lock(); frame = newFrame; lock.unlock() }
    var value: GuestFrame? { lock.lock(); defer { lock.unlock() }; return frame }
}
let collector = Task {
    for await event in frames { if case .scanout(let frame) = event { latestFrame.store(frame) } }
}

let input = QEMUInputClient(connection: console)
row("waiting", "\(shellDelaySeconds)s for the guest shell")
try? await Task.sleep(for: .seconds(shellDelaySeconds))

let beforeFrame = latestFrame.value
let beforeLit = beforeFrame?.nonBlackFraction() ?? 0

// --- Keyboard ---
let command = "echo \(marker) > /dev/ttyAMA0\n"
row("typing", command.trimmingCharacters(in: .newlines))
do {
    try await input.type(command)
} catch {
    qemu.kill(); fail("typing failed: \(error)")
}

try? await Task.sleep(for: .seconds(3))

// --- Pointer and touch: confirm QEMU accepts the calls ---
let absolutePointer = await input.isPointerAbsolute()
row("pointer device", absolutePointer ? "absolute (tablet)" : "relative (mouse)")
row("max touch slots", "\(await input.maxTouchSlots())")
row("console geometry", (await input.consoleGeometry()).map { "\(Int($0.width))×\(Int($0.height))" } ?? "unknown")

var pointerAccepted = true
do {
    // move(to:) picks SetAbsPosition or RelMotion based on the device kind;
    // sending the wrong one is refused outright by QEMU.
    try await input.move(to: CGPoint(x: 640, y: 400))
    try await input.click(.left)
    try await input.move(to: CGPoint(x: 665, y: 385))
    try await input.scroll(lines: 2)
} catch {
    pointerAccepted = false
    row("pointer", "REJECTED: \(error)")
}
var touchAccepted = true
do {
    try await input.tapTouch(at: CGPoint(x: 320, y: 240))
} catch {
    touchAccepted = false
    row("multi-touch", "REJECTED: \(error)")
}
var uiInfoAccepted = true
do {
    try await input.setUIInfo(width: 1280, height: 800)
} catch {
    uiInfoAccepted = false
    row("SetUIInfo", "REJECTED: \(error)")
}
await input.releaseAll()

try? await Task.sleep(for: .seconds(1))

// --- Did the keystrokes reach the guest? ---
let serialText = (try? String(contentsOf: serialLog, encoding: .utf8)) ?? ""
let markerFound = serialText.contains(marker)

let afterFrame = latestFrame.value
let afterLit = afterFrame?.nonBlackFraction() ?? 0

print("")
print("Results")
row("marker echoed over serial", markerFound ? "YES — keystrokes reached the guest" : "NO")
row("framebuffer changed", String(format: "%.2f%% -> %.2f%% lit", beforeLit * 100, afterLit * 100))
row("pointer calls accepted", pointerAccepted ? "yes" : "NO")
row("multi-touch accepted", touchAccepted ? "yes" : "NO")
row("SetUIInfo accepted", uiInfoAccepted ? "yes" : "NO")

if let afterFrame {
    let url = outputDirectory.appendingPathComponent("after-typing.png")
    try? afterFrame.writePNG(to: url)
    row("frame after typing", url.path)
}

if !markerFound, !serialText.isEmpty {
    print("\n  last serial output:")
    for line in serialText.split(separator: "\n").suffix(6) { print("    \(line)") }
}

let passed = markerFound && pointerAccepted && touchAccepted && uiInfoAccepted
print("")
print(passed
    ? "RESULT: PASS — keyboard input reaches the guest; pointer and touch interfaces accepted."
    : "RESULT: FAIL — see above.")

collector.cancel()
await display.close()
qemu.kill()
drain.cancel()
exit(passed ? 0 : 2)
