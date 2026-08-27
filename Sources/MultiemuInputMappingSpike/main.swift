import Darwin
import Foundation
import MultiemuBackend
import MultiemuDBus
import MultiemuGraphics
import MultiemuHost
import MultiemuInput
import MultiemuQEMU
import MultiemuSupport

// multiemu-input-mapping-spike — Milestone 16 verification.
//
// Checks that the events a mapping produces are actually ACCEPTED by QEMU and
// routed to a multitouch device — and, crucially, that they are REFUSED when no
// such device exists.
//
// That control is the whole point. "QEMU accepted our touches" means nothing on
// its own: an interface that accepts anything would pass. The run without a
// multitouch device is what turns acceptance into evidence.
//
// What this does NOT prove: the coordinates a guest ultimately reads. The Linux
// fixture has no evdev interface at all — its initramfs runs no udev and the
// handler is absent, so `/sys/class/input/inputN` has no `eventN` and
// `/dev/input` does not exist. Guest-side observation waits for an Android
// guest (Milestone 4). See docs/VERIFY.md.

setvbuf(stdout, nil, _IONBF, 0)

func row(_ label: String, _ value: String) {
    print("  \(label.padding(toLength: 52, withPad: " ", startingAt: 0)) \(value)")
}
func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("multiemu-input-mapping-spike: \(message)\n".utf8))
    exit(code)
}

var kernelURL: URL?
var initrdURL: URL?
var argv = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < argv.count {
    func next() -> String { index += 1; return index < argv.count ? argv[index] : "" }
    switch argv[index] {
    case "--kernel": kernelURL = URL(fileURLWithPath: next())
    case "--initrd": initrdURL = URL(fileURLWithPath: next())
    default: break
    }
    index += 1
}
guard let kernel = kernelURL else { fail("--kernel is required", code: 64) }
guard let qemuPath = ExternalToolProbe.resolve("qemu-system-aarch64") else {
    fail("qemu-system-aarch64 not found", code: 65)
}

let guestWidth = 1280
let guestHeight = 720
// Deliberately off-centre and not square: a mapping that swapped its axes or
// dropped its scaling would still land plausibly at the middle.
let mappedPoint = NormalizedPoint(x: 0.75, y: 0.25)

let profile = InputProfile(name: "Spike", bindings: [
    InputBinding(label: "Primary", trigger: .key(.space), action: .touch(mappedPoint)),
    InputBinding(label: "Move up", trigger: .key(.w), action: .stick(
        StickBinding(stickID: "move", center: NormalizedPoint(x: 0.2, y: 0.7),
                     radius: 0.1, direction: .up))),
])

struct Attempt {
    var maxSlots: Int
    var accepted: Bool
    var failure: String?
    /// What the guest's own kernel said about its input devices.
    var guestEnumerated: [String] = []
}

/// Boots a guest, attaches the display channel, and tries to deliver the events
/// one press of each mapped control produces.
@MainActor
func attemptDelivery(withMultiTouchDevice: Bool) async -> Attempt {
    let socketPath = QMPClient.makeSocketPath(role: "mapping")
    let serialLog = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("multiemu-mapping-\(UUID().uuidString).log")
    var arguments = [
        "-machine", "virt", "-accel", "hvf", "-cpu", "host",
        "-smp", "2", "-m", "1024",
        "-device", "virtio-gpu-pci,xres=\(guestWidth),yres=\(guestHeight)",
        "-device", "virtio-keyboard-pci",
        "-device", "virtio-tablet-pci",
        "-display", "dbus,p2p=on",
        "-kernel", kernel.path,
        "-append", "console=ttyAMA0",
        "-serial", "file:\(serialLog.path)",
        "-qmp", "unix:\(socketPath),server=on,wait=off",
        "-no-reboot",
    ]
    if withMultiTouchDevice {
        arguments.insert(contentsOf: ["-device", "virtio-multitouch-pci"], at: arguments.count)
    }
    if let initrd = initrdURL { arguments += ["-initrd", initrd.path] }

    let qemu = QEMUProcess(executableURL: URL(fileURLWithPath: qemuPath), arguments: arguments)
    let events = qemu.events
    let drain = Task { for await _ in events {} }
    do { try qemu.start() } catch {
        return Attempt(maxSlots: 0, accepted: false, failure: "QEMU did not start: \(error)")
    }
    defer { qemu.kill(); drain.cancel() }

    let control = QMPClient()
    do { _ = try await control.connect(toSocketAt: socketPath, timeout: .seconds(20)) }
    catch { return Attempt(maxSlots: 0, accepted: false, failure: "QMP did not connect: \(error)") }

    var descriptors: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        return Attempt(maxSlots: 0, accepted: false, failure: "socketpair failed")
    }
    do {
        try await control.sendFileDescriptor(descriptors[1], named: "displayfd")
        try await control.addClient(protocolName: "@dbus-display", fileDescriptorName: "displayfd")
    } catch {
        Darwin.close(descriptors[0]); Darwin.close(descriptors[1])
        return Attempt(maxSlots: 0, accepted: false, failure: "display channel refused: \(error)")
    }
    Darwin.close(descriptors[1])

    let connection = DBusConnection(descriptor: descriptors[0], role: .client)
    do { try await connection.authenticate() } catch {
        return Attempt(maxSlots: 0, accepted: false, failure: "D-Bus handshake failed: \(error)")
    }
    let input = QEMUInputClient(connection: connection)
    let slots = await input.maxTouchSlots()

    var mapper = InputMapper(
        profile: profile,
        guestSize: CGSize(width: guestWidth, height: guestHeight),
        maximumSlots: slots > 0 ? slots : 10)
    let produced = mapper.keyDown(.space) + mapper.keyDown(.w)
        + mapper.keyUp(.w) + mapper.keyUp(.space)

    for event in produced {
        do {
            switch event {
            case let .touchBegin(slot, x, y): try await input.touch(.begin, slot: slot, x: x, y: y)
            case let .touchUpdate(slot, x, y): try await input.touch(.update, slot: slot, x: x, y: y)
            case let .touchEnd(slot, x, y): try await input.touch(.end, slot: slot, x: x, y: y)
            case let .keyPress(key): try await input.press(key)
            case let .keyRelease(key): try await input.release(key)
            }
        } catch {
            return Attempt(maxSlots: slots, accepted: false, failure: String(describing: error))
        }
    }
    await connection.close()

    // The guest's own kernel log is the only account here that does not come
    // from the host: it names the input devices Linux actually enumerated.
    try? await Task.sleep(for: .seconds(3))
    let log = (try? String(contentsOf: serialLog, encoding: .utf8)) ?? ""
    let enumerated = log.split(whereSeparator: \.isNewline)
        .filter { $0.contains("input: QEMU Virtio") }
        .map { line -> String in
            let text = String(line)
            guard let start = text.range(of: "input: "), let end = text.range(of: " as ") else { return text }
            return String(text[start.upperBound..<end.lowerBound])
        }
    try? FileManager.default.removeItem(at: serialLog)
    return Attempt(maxSlots: slots, accepted: true, failure: nil, guestEnumerated: enumerated)
}

print("multiemu-input-mapping-spike")
row("qemu", qemuPath)
row("guest display", "\(guestWidth)×\(guestHeight)")
print("")

// --- What the mapping produces, independent of any guest ---
var offline = InputMapper(
    profile: profile, guestSize: CGSize(width: guestWidth, height: guestHeight))
let pressEvents = offline.keyDown(.space)
print("One press of the mapped key produces")
for event in pressEvents { print("    \(event)") }
row("profile position", String(format: "(%.2f, %.2f)", mappedPoint.x, mappedPoint.y))
row("expected guest pixels",
    String(format: "(%.0f, %.0f)", mappedPoint.x * Double(guestWidth), mappedPoint.y * Double(guestHeight)))
let landsWhereAsked = pressEvents == [
    .touchBegin(slot: 0, x: mappedPoint.x * Double(guestWidth), y: mappedPoint.y * Double(guestHeight)),
]
row("lands where the profile asked", landsWhereAsked ? "PASS" : "FAIL")
print("")

// --- With a multitouch device ---
print("1. With a multitouch device attached")
let withDevice = await attemptDelivery(withMultiTouchDevice: true)
row("MultiTouch.MaxSlots", "\(withDevice.maxSlots)")
row("QEMU accepted the mapped events", withDevice.accepted ? "yes" : "no — \(withDevice.failure ?? "")")
row("guest kernel enumerated", withDevice.guestEnumerated.isEmpty
    ? "nothing" : withDevice.guestEnumerated.joined(separator: ", "))
let guestSeesMultiTouch = withDevice.guestEnumerated.contains { $0.contains("MultiTouch") }
row("guest sees a multitouch device", guestSeesMultiTouch ? "PASS" : "FAIL")
print("")

// --- Control: without one ---
print("2. CONTROL — the same events, no multitouch device")
print("   Without this, \"QEMU accepted them\" would prove nothing.")
let withoutDevice = await attemptDelivery(withMultiTouchDevice: false)
row("MultiTouch.MaxSlots", "\(withoutDevice.maxSlots)")
row("QEMU accepted the mapped events", withoutDevice.accepted ? "yes" : "no")
row("guest kernel enumerated", withoutDevice.guestEnumerated.isEmpty
    ? "nothing" : withoutDevice.guestEnumerated.joined(separator: ", "))
if let failure = withoutDevice.failure {
    for line in failure.split(whereSeparator: \.isNewline).prefix(2) {
        print("      \(line.trimmingCharacters(in: .whitespaces))")
    }
}
print("")

let controlDiscriminates = withDevice.accepted && !withoutDevice.accepted
let guestWithout = withoutDevice.guestEnumerated.contains { $0.contains("MultiTouch") }

let checks: [(String, Bool)] = [
    ("mapping puts the touch where the profile asked", landsWhereAsked),
    ("guest enumerates a multitouch device when configured", guestSeesMultiTouch),
    ("guest enumerates none when it is not configured", !guestWithout),
    ("QEMU accepts the mapped events", withDevice.accepted),
]
print("Result")
for (name, ok) in checks { row(name, ok ? "PASS" : "FAIL") }

print("")
print("What this run does and does not establish")
print("  The device half is settled by the guest itself: Linux enumerates")
print("  \"QEMU Virtio MultiTouch\" only when it is configured, so the device")
print("  reaches the guest kernel.")
print("")
if controlDiscriminates {
    print("  Acceptance is also discriminating — QEMU refuses the events without a device.")
} else {
    print("  Acceptance is NOT discriminating: QEMU accepted the same events with no")
    print("  multitouch device attached, and still reported MaxSlots = \(withoutDevice.maxSlots).")
    print("  So \"QEMU accepted them\" is not evidence of delivery, and is not claimed as such.")
}
print("")
print("  UNVERIFIED: the coordinates a guest ultimately reads. The Linux fixture")
print("  has no evdev interface — its initramfs runs no udev, the handler is")
print("  absent, /sys/class/input/inputN has no eventN and /dev/input does not")
print("  exist — so nothing in the guest can observe a touch. That waits for an")
print("  Android guest (Milestone 4).")

exit(checks.allSatisfy(\.1) ? 0 : 1)
