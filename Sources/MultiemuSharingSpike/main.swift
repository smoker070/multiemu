import Darwin
import Foundation
import MultiemuBackend
import MultiemuDBus
import MultiemuGraphics
import MultiemuHost
import MultiemuInput
import MultiemuQEMU
import MultiemuSupport

// multiemu-sharing-spike — Milestone 14 verification.
//
// Checks the two halves of file exchange and clipboard that CAN be checked
// here, and says plainly which half cannot.
//
// The confinement rules are covered by tests, not by this spike: they are pure
// host logic and a live guest adds nothing to them. What needs a guest is
// whether the share reaches it at all, and whether QEMU's clipboard channel
// answers.

setvbuf(stdout, nil, _IONBF, 0)

func row(_ label: String, _ value: String) {
    print("  \(label.padding(toLength: 44, withPad: " ", startingAt: 0)) \(value)")
}
func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("multiemu-sharing-spike: \(message)\n".utf8))
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

// A share whose name contains a comma, because QEMU splits its options on
// commas and the escaping is exactly the kind of thing that works in a test and
// fails on a real user's folder.
let shareRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("multiemu share, with comma-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: shareRoot, withIntermediateDirectories: true)
let marker = "MULTIEMU_SHARED_\(UInt32.random(in: 100_000...999_999))"
try? Data("\(marker)\n".utf8).write(to: shareRoot.appendingPathComponent("marker.txt"))

let share: SharedFolder
do {
    share = try SharedFolder(hostDirectory: shareRoot, mountTag: "multiemu", isReadOnly: true)
} catch {
    fail("could not create the share: \(error)")
}

print("multiemu-sharing-spike")
row("qemu", qemuPath)
row("host directory", share.hostDirectory.lastPathComponent)
row("mount tag", share.mountTag)
row("read-only", share.isReadOnly ? "yes" : "no")
print("")

/// Boots a guest, optionally exporting the share, and reports what the guest
/// enumerated plus whether the clipboard channel answered.
@MainActor
func boot(withShare: Bool) async -> (started: Bool, virtioDevices: Int, clipboard: String, error: String?) {
    let socketPath = QMPClient.makeSocketPath(role: "sharing")
    let serialLog = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("multiemu-sharing-\(UUID().uuidString).log")

    var arguments = [
        "-machine", "virt", "-accel", "hvf", "-cpu", "host",
        "-smp", "2", "-m", "1024",
        "-device", "virtio-gpu-pci,xres=1280,yres=720",
        "-display", "dbus,p2p=on",
        "-kernel", kernel.path,
        "-append", "console=ttyAMA0",
        "-serial", "file:\(serialLog.path)",
        "-qmp", "unix:\(socketPath),server=on,wait=off",
        "-no-reboot",
    ]
    if withShare {
        // Built by the production builder, so the escaping under test is the
        // escaping that ships.
        let configuration = try? QEMUConfiguration(
            executableURL: URL(fileURLWithPath: qemuPath),
            guestArchitecture: .arm64,
            acceleration: .hardwareVirtualization,
            vcpuCount: 2,
            memoryBytes: 1024 * ByteCount.miB,
            kernelURL: kernel,
            sharedFolders: [share])
        if let configuration, let built = try? QEMUCommandBuilder.arguments(for: configuration) {
            var carry: String?
            for argument in built {
                if argument == "-fsdev" || argument == "-device" { carry = argument; continue }
                if let flag = carry {
                    if argument.hasPrefix("local,") || argument.contains("virtio-9p-pci") {
                        arguments += [flag, argument]
                    }
                    carry = nil
                }
            }
        }
    }
    if let initrd = initrdURL { arguments += ["-initrd", initrd.path] }

    let qemu = QEMUProcess(executableURL: URL(fileURLWithPath: qemuPath), arguments: arguments)
    let events = qemu.events
    let drain = Task { for await _ in events {} }
    do { try qemu.start() } catch {
        return (false, 0, "not attempted", "QEMU did not start: \(error)")
    }
    defer {
        qemu.kill(); drain.cancel()
        try? FileManager.default.removeItem(at: serialLog)
    }

    let control = QMPClient()
    do { _ = try await control.connect(toSocketAt: socketPath, timeout: .seconds(20)) }
    catch { return (false, 0, "not attempted", "QMP did not connect: \(error)") }

    // --- Clipboard, over the same D-Bus display channel ---
    var clipboardResult = "not attempted"
    var descriptors: [Int32] = [0, 0]
    if socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 {
        do {
            try await control.sendFileDescriptor(descriptors[1], named: "displayfd")
            try await control.addClient(protocolName: "@dbus-display", fileDescriptorName: "displayfd")
            Darwin.close(descriptors[1])
            let connection = DBusConnection(descriptor: descriptors[0], role: .client)
            try await connection.authenticate()
            let clipboard = QEMUClipboardClient(connection: connection)
            try await clipboard.register()
            clipboardResult = "Register accepted"
            do {
                try await clipboard.offerText()
                clipboardResult += "; Grab accepted"
            } catch {
                clipboardResult += "; Grab refused"
            }
            do {
                _ = try await clipboard.requestText()
                clipboardResult += "; Request returned text"
            } catch {
                clipboardResult += "; Request failed (no guest agent)"
            }
            await connection.close()
        } catch {
            Darwin.close(descriptors[0]); Darwin.close(descriptors[1])
            clipboardResult = "channel failed: \(error)"
        }
    }

    try? await Task.sleep(for: .seconds(4))
    let log = (try? String(contentsOf: serialLog, encoding: .utf8)) ?? ""
    let devices = log.split(whereSeparator: \.isNewline)
        .filter { $0.contains("virtio-pci") && $0.contains("enabling device") }
        .count
    return (true, devices, clipboardResult, nil)
}

print("1. Does the share reach the guest?")
let withShare = await boot(withShare: true)
let withoutShare = await boot(withShare: false)

row("QEMU started with the share", withShare.started ? "yes" : "no — \(withShare.error ?? "")")
row("virtio PCI devices the guest enabled, with share", "\(withShare.virtioDevices)")
row("virtio PCI devices the guest enabled, without", "\(withoutShare.virtioDevices)")
let shareReachesGuest = withShare.started && withShare.virtioDevices > withoutShare.virtioDevices
row("the share adds a device the guest sees", shareReachesGuest ? "PASS" : "FAIL")
print("")

print("2. Does QEMU's clipboard channel answer?")
row("with a share", withShare.clipboard)
row("without a share", withoutShare.clipboard)
let clipboardRegisters = withShare.clipboard.contains("Register accepted")
row("the host can register as a clipboard peer", clipboardRegisters ? "PASS" : "FAIL")
print("")

print("3. Confinement (covered by tests; restated here as a live check)")
var confinementHolds = true
for attempt in ["../../etc/passwd", "/etc/passwd", "marker.txt\u{0}/../../etc/passwd", ".."] {
    let allowed = (try? share.resolve(guestPath: attempt)) != nil
    if allowed { confinementHolds = false }
    row("guest asked for \(attempt.replacingOccurrences(of: "\u{0}", with: "\\0"))",
        allowed ? "ALLOWED — escape" : "refused")
}
let insideResolves = (try? share.resolve(guestPath: "marker.txt")) != nil
row("guest asked for marker.txt", insideResolves ? "resolved inside the share" : "REFUSED")
row("confinement holds", confinementHolds && insideResolves ? "PASS" : "FAIL")

let checks: [(String, Bool)] = [
    ("the share reaches the guest as a device", shareReachesGuest),
    ("the host registers as a clipboard peer", clipboardRegisters),
    ("guest paths are confined to the share", confinementHolds && insideResolves),
]
print("")
print("Result")
for (name, ok) in checks { row(name, ok ? "PASS" : "FAIL") }

print("")
print("What this cannot establish here")
print("  The guest cannot MOUNT the share: this fixture's kernel has no 9p")
print("  driver, built in or as a module, so nothing inside it can read the")
print("  shared directory. Reading a shared file from a guest waits for an")
print("  Android guest (Milestone 4) — and whether 9p is even the right")
print("  transport for Android is itself open.")
print("")
print("  Clipboard text cannot cross either: QEMU mediates between this")
print("  process and a guest clipboard agent, and neither this fixture nor a")
print("  stock Android image runs one.")

try? FileManager.default.removeItem(at: shareRoot)
exit(checks.allSatisfy(\.1) ? 0 : 1)
