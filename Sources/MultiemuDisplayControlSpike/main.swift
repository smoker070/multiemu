import Darwin
import Foundation
import MultiemuBackend
import MultiemuConfiguration
import MultiemuDBus
import MultiemuGraphics
import MultiemuHost
import MultiemuInput
import MultiemuQEMU
import MultiemuSupport

// multiemu-display-control-spike — Milestone 12 verification.
//
// Applies display profiles to a RUNNING guest and reports what the guest
// actually did, by measuring the scanouts it sends back. The guest is the
// witness: nothing here trusts that a request was honoured because it was
// accepted.

setvbuf(stdout, nil, _IONBF, 0)

func row(_ label: String, _ value: String) {
    print("  \(label.padding(toLength: 30, withPad: " ", startingAt: 0)) \(value)")
}
func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("multiemu-display-control-spike: \(message)\n".utf8))
    exit(code)
}

var kernelURL: URL?
var initrdURL: URL?
var settleSeconds = 4
// Defaults to what the product actually allocates, so a plain run reports the
// shipped configuration. `--start` exists to demonstrate the rule by breaking
// it: a smaller allocation refuses the larger modes.
var startWidth = DisplayProfile.runtimeFramebufferSide
var startHeight = DisplayProfile.runtimeFramebufferSide
var argv = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < argv.count {
    func next() -> String { index += 1; return index < argv.count ? argv[index] : "" }
    switch argv[index] {
    case "--kernel": kernelURL = URL(fileURLWithPath: next())
    case "--initrd": initrdURL = URL(fileURLWithPath: next())
    case "--settle": settleSeconds = Int(next()) ?? 4
    case "--start":
        let parts = next().split(separator: "x").compactMap { Int($0) }
        if parts.count == 2 {
            startWidth = parts[0]; startHeight = parts[1]
        }
    default: break
    }
    index += 1
}
guard let kernel = kernelURL else { fail("--kernel is required", code: 64) }
guard let qemuPath = ExternalToolProbe.resolve("qemu-system-aarch64") else {
    fail("qemu-system-aarch64 not found", code: 65)
}

let startingProfile = DisplayProfile(
    widthInPixels: startWidth, heightInPixels: startHeight, densityDPI: 240)

print("multiemu-display-control-spike")
row("qemu", qemuPath)
row("boot allocation", "\(startingProfile.widthInPixels)×\(startingProfile.heightInPixels)")
let usesShippedAllocation = startWidth == DisplayProfile.runtimeFramebufferSide
    && startHeight == DisplayProfile.runtimeFramebufferSide
row("matches the shipped value", usesShippedAllocation
    ? "yes (DisplayProfile.runtimeFramebufferSide)"
    : "no — demonstrating the rule by breaking it")
print("")

let socketPath = QMPClient.makeSocketPath(role: "display-control")
var arguments = [
    "-machine", "virt", "-accel", "hvf", "-cpu", "host",
    "-smp", "2", "-m", "1024",
    "-device", "virtio-gpu-pci,xres=\(startingProfile.widthInPixels),yres=\(startingProfile.heightInPixels)",
    "-display", "dbus,p2p=on",
    "-kernel", kernel.path,
    "-append", "console=ttyAMA0",
    "-serial", "null",
    "-qmp", "unix:\(socketPath),server=on,wait=off",
    "-no-reboot",
]
if let initrd = initrdURL { arguments += ["-initrd", initrd.path] }

let qemu = QEMUProcess(executableURL: URL(fileURLWithPath: qemuPath), arguments: arguments)
let qemuEvents = qemu.events
let drain = Task { for await _ in qemuEvents {} }
do { try qemu.start() } catch { fail("could not start QEMU: \(error)") }

@MainActor
func shutDown(_ code: Int32) -> Never {
    qemu.kill()
    drain.cancel()
    exit(code)
}

let control = QMPClient()
do { _ = try await control.connect(toSocketAt: socketPath, timeout: .seconds(20)) }
catch { qemu.kill(); drain.cancel(); fail("QMP did not connect: \(error)") }

var descriptors: [Int32] = [0, 0]
guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { shutDown(2) }
do {
    try await control.sendFileDescriptor(descriptors[1], named: "displayfd")
    try await control.addClient(protocolName: "@dbus-display", fileDescriptorName: "displayfd")
} catch {
    Darwin.close(descriptors[0]); Darwin.close(descriptors[1])
    qemu.kill(); drain.cancel(); fail("display channel refused: \(error)")
}
Darwin.close(descriptors[1])

let connection = DBusConnection(descriptor: descriptors[0], role: .client)
do { try await connection.authenticate() } catch {
    qemu.kill(); drain.cancel(); fail("D-Bus handshake failed: \(error)")
}

let display = QEMUDisplayClient(consoleConnection: connection)
let frames = display.events
do { try await display.registerListener() } catch {
    qemu.kill(); drain.cancel(); fail("could not register a display listener: \(error)")
}
let input = QEMUInputClient(connection: connection)

/// The most recent scanout the guest produced, as an actor so the reader task
/// and the main flow do not race on it.
actor LatestScanout {
    private var size: (width: Int, height: Int)?
    private var count = 0
    func record(width: Int, height: Int) { size = (width, height); count += 1 }
    func current() -> (width: Int, height: Int)? { size }
    func total() -> Int { count }
}
let latest = LatestScanout()

let reader = Task {
    for await event in frames {
        if case let .scanout(frame) = event {
            await latest.record(width: frame.width, height: frame.height)
        }
    }
}

// Let the guest boot and produce its first scanout.
try? await Task.sleep(for: .seconds(settleSeconds))
guard let initial = await latest.current() else {
    reader.cancel()
    shutDown(1)
}
row("guest's first scanout", "\(initial.width)×\(initial.height)")
print("")

struct Outcome {
    var label: String
    var requested: DisplayProfile
    var observed: (width: Int, height: Int)?
    var honoured: Bool
}

/// Asks the guest to change mode, then reports what it actually produced.
@MainActor
func apply(_ profile: DisplayProfile, label: String) async -> Outcome {
    let before = await latest.total()
    do {
        try await input.setUIInfo(
            width: UInt32(profile.widthInPixels), height: UInt32(profile.heightInPixels))
    } catch {
        return Outcome(label: label, requested: profile, observed: nil, honoured: false)
    }

    // Wait for the guest to act, but no longer than it needs to.
    let deadline = Date().addingTimeInterval(Double(settleSeconds))
    while Date() < deadline {
        if await latest.total() > before,
           let size = await latest.current(),
           size.width == profile.widthInPixels, size.height == profile.heightInPixels {
            break
        }
        try? await Task.sleep(for: .milliseconds(200))
    }
    let observed = await latest.current()
    return Outcome(
        label: label, requested: profile, observed: observed,
        honoured: observed?.width == profile.widthInPixels
            && observed?.height == profile.heightInPixels)
}

var outcomes: [Outcome] = []

print("Applying every preset to the running guest")
for preset in DisplayProfile.allPresets {
    outcomes.append(await apply(preset.profile, label: preset.name))
}

print("")
print("Rotating at runtime")
let landscape = DisplayProfile(widthInPixels: 1600, heightInPixels: 900, densityDPI: 240)
outcomes.append(await apply(landscape, label: "before rotation"))
outcomes.append(await apply(landscape.rotated(), label: "after rotation"))

print("")
print(String(format: "  %-24s %-14s %-14s %s", ("requested" as NSString).utf8String!,
             ("asked for" as NSString).utf8String!,
             ("guest produced" as NSString).utf8String!,
             ("honoured" as NSString).utf8String!))
for outcome in outcomes {
    let asked = "\(outcome.requested.widthInPixels)×\(outcome.requested.heightInPixels)"
    let got = outcome.observed.map { "\($0.width)×\($0.height)" } ?? "none"
    print(String(format: "  %-24@ %-14@ %-14@ %@",
                 outcome.label as NSString, asked as NSString, got as NSString,
                 (outcome.honoured ? "yes" : "NO") as NSString))
}

let honoured = outcomes.filter(\.honoured).count
print("")
row("modes honoured", "\(honoured) of \(outcomes.count)")
row("total scanouts observed", "\(await latest.total())")
print("")
if usesShippedAllocation {
    print(honoured == outcomes.count
          ? "  Every preset and the rotation applied to a running guest, with no restart."
          : "  A mode the shipped allocation should cover was refused — the rule has changed.")
} else {
    print("  Ran with a non-shipping allocation, so a refusal here is the expected")
    print("  demonstration rather than a defect.")
}

reader.cancel()
shutDown(honoured == outcomes.count ? 0 : 1)
