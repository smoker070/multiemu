import AppKit
import Darwin
import Foundation
import MultiemuBackend
import MultiemuDBus
import MultiemuGraphics
import MultiemuHost
import MultiemuInput
import MultiemuQEMU
import MultiemuSupport
import MultiemuUI

// multiemu-display-window — Milestone 5 end-to-end demonstration.
//
// Boots a guest, receives its frames over QEMU's D-Bus display channel, and
// presents them in a real macOS window through Metal. Captures the displayed
// image at guest resolution and exits, so the run is verifiable without anyone
// watching the screen.
//
//   multiemu-display-window --kernel <path> --initrd <path>
//                           [--seconds <n>] [--out <dir>] [--scaling <mode>]

setvbuf(stdout, nil, _IONBF, 0)

struct Options {
    var kernel: URL?
    var initrd: URL?
    var seconds = 15
    var outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    var scaling: GuestDisplayScaling = .aspectFit
    var width = 1280
    var height = 800
}

var options = Options()
var argv = Array(CommandLine.arguments.dropFirst())
var argumentIndex = 0
while argumentIndex < argv.count {
    func next() -> String { argumentIndex += 1; return argumentIndex < argv.count ? argv[argumentIndex] : "" }
    switch argv[argumentIndex] {
    case "--kernel": options.kernel = URL(fileURLWithPath: next())
    case "--initrd": options.initrd = URL(fileURLWithPath: next())
    case "--seconds": options.seconds = Int(next()) ?? 15
    case "--out": options.outputDirectory = URL(fileURLWithPath: next())
    case "--width": options.width = Int(next()) ?? 1280
    case "--height": options.height = Int(next()) ?? 800
    case "--scaling": options.scaling = GuestDisplayScaling(rawValue: next()) ?? .aspectFit
    case "-h", "--help":
        print("multiemu-display-window --kernel <path> [--initrd <path>] [--seconds <n>] [--out <dir>] [--scaling aspectFit|aspectFill|stretch|integerScale]")
        exit(0)
    default: break
    }
    argumentIndex += 1
}

func row(_ label: String, _ value: String) {
    print("  \(label.padding(toLength: 30, withPad: " ", startingAt: 0)) \(value)")
}
func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("multiemu-display-window: \(message)\n".utf8))
    exit(code)
}

guard let qemuPath = ExternalToolProbe.resolve("qemu-system-aarch64") else {
    fail("qemu-system-aarch64 not found on PATH", code: 65)
}

print("multiemu-display-window")
row("qemu", qemuPath)
row("scaling", options.scaling.rawValue)
row("run time", "\(options.seconds)s, then capture and exit")

// --- Window and renderer, on the main actor ---
let renderer: GuestDisplayRenderer
do {
    renderer = try GuestDisplayRenderer()
} catch {
    fail("Metal renderer unavailable: \(error)")
}
row("metal device", renderer.device.name)

let application = NSApplication.shared
application.setActivationPolicy(.regular)

let displayView = GuestDisplayView(renderer: renderer)
displayView.scaling = options.scaling

// Deliberately not the guest's resolution: the point is that the guest's
// logical resolution stays independent of the window size.
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false
)
window.title = "Multiemu — guest display"
window.contentView = displayView
window.center()
window.makeKeyAndOrderFront(nil)
application.activate(ignoringOtherApps: true)

row("window", "900×620 points")
row("backing scale", String(format: "%.1f×", displayView.backingScaleFactor))
row("drawable", "\(Int(displayView.drawableSizeInPixels.width))×\(Int(displayView.drawableSizeInPixels.height)) pixels")
print("")

// --- Guest, off the main actor ---
let socketPath = QMPClient.makeSocketPath(role: "window")
try? FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
let serialLogPath = options.outputDirectory.appendingPathComponent("window-serial.log").path
try? FileManager.default.removeItem(atPath: serialLogPath)
let inputMarker = "MULTIEMU_WINDOW_INPUT_\(UInt32.random(in: 100_000...999_999))"
var qemuArguments = [
    "-machine", "virt", "-accel", "hvf", "-cpu", "host",
    "-smp", "4", "-m", "2048",
    "-device", "virtio-gpu-pci,xres=\(options.width),yres=\(options.height)",
    "-device", "virtio-keyboard-pci",
    "-device", "virtio-tablet-pci",
    "-display", "dbus,p2p=on",
    "-serial", "file:\(serialLogPath)",
    "-qmp", "unix:\(socketPath),server=on,wait=off",
    "-no-reboot",
]
if let kernel = options.kernel {
    qemuArguments += ["-kernel", kernel.path]
    if let initrd = options.initrd { qemuArguments += ["-initrd", initrd.path] }
    // tty0 last, so /dev/console is the framebuffer and keyboard input reaches
    // the shell; ttyAMA0 stays available for the verification marker.
    qemuArguments += ["-append", "console=ttyAMA0 console=tty0"]
}

/// Reports a fatal setup failure and stops.
///
/// Declared as returning `Void` rather than `Never` on purpose: a `Never`
/// helper called from inside `MainActor.run` makes the compiler treat the rest
/// of every enclosing block as unreachable, which buries real warnings under
/// noise. It still terminates, via `exit`.
@MainActor
func abortRun(_ message: String, code: Int32 = 2) {
    FileHandle.standardError.write(Data("multiemu-display-window: \(message)\n".utf8))
    exit(code)
}

let qemu = QEMUProcess(executableURL: URL(fileURLWithPath: qemuPath), arguments: qemuArguments)
let frameCounter = FrameCounter()

/// Counts frames across actor boundaries without a shared mutable global.
final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

do { try qemu.start() } catch { fail("could not start QEMU: \(error)") }

Task.detached {
    let control = QMPClient()
    do {
        _ = try await control.connect(toSocketAt: socketPath, timeout: .seconds(15))
    } catch {
        await MainActor.run { abortRun("QMP connect failed: \(error)") }
        return
    }

    var descriptors: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        await MainActor.run { abortRun("socketpair failed") }
        return
    }
    do {
        try await control.sendFileDescriptor(descriptors[1], named: "displayfd")
        try await control.addClient(protocolName: "@dbus-display", fileDescriptorName: "displayfd")
    } catch {
        await MainActor.run { abortRun("display attach failed: \(error)") }
        return
    }
    Darwin.close(descriptors[1])

    let console = DBusConnection(descriptor: descriptors[0], role: .client)
    do { try await console.authenticate() } catch {
        await MainActor.run { abortRun("D-Bus authentication failed: \(error)") }
        return
    }

    let display = QEMUDisplayClient(consoleConnection: console)
    let stream = display.events
    do { try await display.registerListener() } catch {
        await MainActor.run { abortRun("RegisterListener failed: \(error)") }
        return
    }
    // Attach input, making the window interactive.
    let input = QEMUInputClient(connection: console)
    let absolute = await input.isPointerAbsolute()
    await MainActor.run { displayView.attachInput(input) }
    print("  listener registered; presenting frames")
    print("  input attached: pointer is \(absolute ? "absolute" : "relative"), "
          + "\(await input.maxTouchSlots()) touch slots\n")

    // Prove input reaches the guest from this process, without anyone typing.
    Task {
        try? await Task.sleep(for: .seconds(10))
        try? await input.type("echo \(inputMarker) > /dev/ttyAMA0\n")
    }

    for await event in stream {
        if case .scanout(let frame) = event {
            frameCounter.increment()
            await MainActor.run { displayView.display(frame) }
        }
    }
}

// --- Capture and exit ---
Task { @MainActor in
    try? await Task.sleep(for: .seconds(options.seconds))

    print("Results")
    row("frames presented", "\(frameCounter.value)")
    row("guest resolution", "\(Int(displayView.guestResolution.width))×\(Int(displayView.guestResolution.height))")
    row("window size", "\(Int(displayView.bounds.width))×\(Int(displayView.bounds.height)) points")
    row("drawable size", "\(Int(displayView.drawableSizeInPixels.width))×\(Int(displayView.drawableSizeInPixels.height)) pixels")
    row("backing scale", String(format: "%.1f×", displayView.backingScaleFactor))

    let serialText = (try? String(contentsOfFile: serialLogPath, encoding: .utf8)) ?? ""
    let inputReached = serialText.contains(inputMarker)
    row("input reached guest", inputReached ? "YES (marker echoed over serial)" : "no")

    var exitCode: Int32 = 0
    if displayView.guestResolution.width > 0 {
        do {
            try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
            let captured = try displayView.captureGuestResolutionFrame()
            let url = options.outputDirectory.appendingPathComponent("window-capture.png")
            try captured.writePNG(to: url)
            row("captured", "\(url.path) at \(captured.width)×\(captured.height)")
            row("non-black pixels", String(format: "%.1f%%", captured.nonBlackFraction() * 100))
            print("\nRESULT: PASS — guest frames presented through Metal in a real window"
                  + (inputReached ? ", and input reached the guest." : "."))
            if !inputReached { exitCode = 2 }
        } catch {
            row("capture", "FAILED: \(error)")
            exitCode = 2
        }
    } else {
        print("\nRESULT: FAIL — no frames arrived.")
        exitCode = 3
    }
    qemu.kill()
    exit(exitCode)
}

application.run()
