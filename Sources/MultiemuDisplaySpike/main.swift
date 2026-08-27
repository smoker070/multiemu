import Darwin
import Foundation
import MultiemuBackend
import MultiemuDBus
import MultiemuGraphics
import MultiemuHost
import MultiemuQEMU
import MultiemuSupport

// multiemu-display-spike — Milestone 5.
//
// Boots a guest, attaches QEMU's D-Bus display channel, registers a listener,
// and receives real scanouts — the frame path that replaces vhost-user-gpu,
// which Milestone 2 proved does not exist on macOS.
//
//   multiemu-display-spike [--kernel <path> --initrd <path>] [--out <dir>]
//                          [--seconds <n>] [--attach-only]

struct Options {
    var kernel: URL?
    var initrd: URL?
    var outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    var captureSeconds = 12
    var attachOnly = false
    var introspect = false
    var width = 1280
    var height = 800
}

var options = Options()
var argv = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < argv.count {
    func next() -> String { index += 1; return index < argv.count ? argv[index] : "" }
    switch argv[index] {
    case "--kernel": options.kernel = URL(fileURLWithPath: next())
    case "--initrd": options.initrd = URL(fileURLWithPath: next())
    case "--out": options.outputDirectory = URL(fileURLWithPath: next())
    case "--seconds": options.captureSeconds = Int(next()) ?? 12
    case "--width": options.width = Int(next()) ?? 1280
    case "--height": options.height = Int(next()) ?? 800
    case "--attach-only": options.attachOnly = true
    case "--introspect": options.introspect = true
    case "-h", "--help":
        print("multiemu-display-spike [--kernel <path> --initrd <path>] [--out <dir>] [--seconds <n>] [--attach-only]")
        exit(0)
    default: break
    }
    index += 1
}

// Unbuffered: this tool is often run with output redirected, and a hang
// with no output is far harder to diagnose than a hang with progress.
setvbuf(stdout, nil, _IONBF, 0)

func row(_ label: String, _ value: String) {
    print("  \(label.padding(toLength: 30, withPad: " ", startingAt: 0)) \(value)")
}
func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("multiemu-display-spike: \(message)\n".utf8))
    exit(code)
}

guard let qemuPath = ExternalToolProbe.resolve("qemu-system-aarch64") else {
    fail("qemu-system-aarch64 not found on PATH", code: 65)
}

let socketPath = QMPClient.makeSocketPath(role: "spike")
var arguments = [
    "-machine", "virt", "-accel", "hvf", "-cpu", "host",
    "-smp", "4", "-m", "2048",
    "-device", "virtio-gpu-pci,xres=\(options.width),yres=\(options.height)",
    // p2p: no session bus. Plain `dbus` fails on macOS with
    // "Cannot spawn a message bus without a machine-id".
    "-display", "dbus,p2p=on",
    "-serial", "none",
    "-qmp", "unix:\(socketPath),server=on,wait=off",
    "-no-reboot",
]
if let kernel = options.kernel {
    arguments += ["-kernel", kernel.path]
    if let initrd = options.initrd { arguments += ["-initrd", initrd.path] }
    // console=tty0 puts the guest console on the virtio-gpu framebuffer, which
    // is what makes the captured frame show something recognisable.
    arguments += ["-append", "console=tty0 console=ttyAMA0"]
}

print("multiemu-display-spike")
row("qemu", qemuPath)
row("gpu", "virtio-gpu-pci \(options.width)x\(options.height)")
row("guest", options.kernel?.lastPathComponent ?? "(none — firmware only)")
print("")

let qemu = QEMUProcess(executableURL: URL(fileURLWithPath: qemuPath), arguments: arguments)
var backendMessages: [String] = []
let drain = Task {
    for await event in qemu.events {
        if case .backendMessage(let message) = event { backendMessages.append(message) }
    }
}
do { try qemu.start() } catch { fail("could not start QEMU: \(error)") }

let clock = ContinuousClock()
let launchedAt = clock.now

let control = QMPClient()
do {
    let greeting = try await control.connect(toSocketAt: socketPath, timeout: .seconds(15))
    row("QMP", "connected, QEMU \(greeting.qemuVersion)")
} catch {
    qemu.kill()
    fail("QMP connect failed: \(error)\n\(backendMessages.joined(separator: "\n"))")
}
row("query-display-options", (try? await control.queryDisplayOptions())?.description ?? "?")

// --- Attach the D-Bus display channel ---
var descriptors: [Int32] = [0, 0]
guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
    qemu.kill(); fail("socketpair failed: \(String(cString: strerror(errno)))")
}
let ourEnd = descriptors[0], qemuEnd = descriptors[1]

do {
    try await control.sendFileDescriptor(qemuEnd, named: "displayfd")
    try await control.addClient(protocolName: "@dbus-display", fileDescriptorName: "displayfd")
    row("add_client @dbus-display", "ACCEPTED")
} catch {
    qemu.kill(); fail("attach failed: \(error)")
}
Darwin.close(qemuEnd)

let consoleConnection = DBusConnection(descriptor: ourEnd, role: .client)
do {
    try await consoleConnection.authenticate()
    row("D-Bus (console channel)", "authenticated as client")
} catch {
    qemu.kill(); fail("D-Bus authentication failed: \(error)")
}

if options.introspect {
    let display = QEMUDisplayClient(consoleConnection: consoleConnection)
    for path in ["/org/qemu/Display1", "/org/qemu/Display1/Console_0",
             "/org/qemu/Display1/VM", "/org/qemu/Display1/Clipboard"] {
        print("\n===== \(path) =====")
        do {
            print(try await display.introspect(path: path))
        } catch {
            print("  (\(error))")
        }
    }
    qemu.kill(); drain.cancel(); exit(0)
}

if options.attachOnly {
    print("\nRESULT: PASS — channel attached (attach-only mode).")
    qemu.kill(); drain.cancel(); exit(0)
}

// --- Register a listener and receive frames ---
let display = QEMUDisplayClient(consoleConnection: consoleConnection)
let frameStream = display.events

do {
    try await display.registerListener()
    row("RegisterListener", "ACCEPTED — Multiemu is now the D-Bus server")
} catch {
    qemu.kill()
    fail("RegisterListener failed: \(error)\n\(backendMessages.suffix(5).joined(separator: "\n"))")
}

try? FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
print("")
print("  waiting up to \(options.captureSeconds)s for scanouts...")

var frameCount = 0
var updateCount = 0
var firstFrameAt: Duration?
var bestFrame: GuestFrame?
var unhandled = Set<String>()
var frameTimestamps: [ContinuousClock.Instant] = []

let deadline = clock.now.advanced(by: .seconds(options.captureSeconds))
let watchdog = Task {
    try? await Task.sleep(until: deadline, clock: clock)
    await display.close()
}

for await event in frameStream {
    switch event {
    case .scanout(let frame):
        frameCount += 1
        frameTimestamps.append(clock.now)
        if firstFrameAt == nil {
            firstFrameAt = clock.now - launchedAt
            print(String(format: "  first scanout at %.3f s: %dx%d stride %d, %@",
                         (firstFrameAt ?? .zero).seconds, frame.width, frame.height,
                         frame.stride, frame.format.description))
        }
        // Keep the frame with the most visible content, so a capture taken
        // while the guest is still black is not what gets written out.
        if bestFrame == nil || frame.nonBlackFraction() > (bestFrame?.nonBlackFraction() ?? 0) {
            bestFrame = frame
        }
    case .update:
        updateCount += 1
    case .disabled:
        print("  display disabled by the guest")
    case .unhandled(let member, let signature):
        if unhandled.insert("\(member)(\(signature))").inserted {
            print("  listener method not implemented: \(member)(\(signature))")
        }
    }
    if clock.now >= deadline { break }
}
watchdog.cancel()

print("")
print("Results")
row("scanouts received", "\(frameCount)")
row("updates received", "\(updateCount)")
row("first frame", firstFrameAt.map { String(format: "%.3f s", $0.seconds) } ?? "none")
if frameTimestamps.count > 1 {
    let span = frameTimestamps.last! - frameTimestamps.first!
    row("scanout rate", String(format: "%.2f /s over %.1f s", Double(frameTimestamps.count - 1) / max(span.seconds, 0.001), span.seconds))
}

var exitCode: Int32 = 2
if let frame = bestFrame {
    row("frame", "\(frame.width)x\(frame.height), \(ByteCount.describe(UInt64(frame.byteCount)))")
    row("format", frame.format.description)
    row("format supported", frame.format.isSupported ? "yes" : "NO")
    row("non-black pixels", String(format: "%.1f%%", frame.nonBlackFraction() * 100))
    let output = options.outputDirectory.appendingPathComponent("dbus-frame.png")
    do {
        try frame.writePNG(to: output)
        let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        row("wrote", "\(output.path) (\(size) bytes)")
        exitCode = 0
    } catch {
        row("PNG", "FAILED: \(error)")
    }
    print("")
    print(exitCode == 0
        ? "RESULT: PASS — guest frames received over D-Bus and written to disk."
        : "RESULT: FAIL — frames received but could not be encoded.")
} else {
    print("")
    print("RESULT: FAIL — the listener registered but no scanout arrived.")
    for message in backendMessages.suffix(8) { print("  qemu: \(message)") }
    exitCode = 3
}

await display.close()
qemu.requestTermination()
drain.cancel()
exit(exitCode)
