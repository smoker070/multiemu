import Darwin
import Foundation
import MultiemuBackend
import MultiemuConfiguration
import MultiemuDBus
import MultiemuDisks
import MultiemuGraphics
import MultiemuHost
import MultiemuInput
import MultiemuQEMU
import MultiemuSupport

// multiemu-snapshot-spike — Milestone 15 verification.
//
// Proves snapshots capture and restore *machine* state, not merely disk state:
//
//   1. set a shell variable (RAM only) and write a marker to the disk
//   2. capture a snapshot
//   3. change both the variable and the disk
//   4. restore the snapshot
//   5. read both back — they must be the pre-snapshot values
//
// Step 5 is the interesting one: a shell variable exists only in guest RAM, so
// recovering it proves RAM was captured, which disk-only checking cannot.

setvbuf(stdout, nil, _IONBF, 0)

func row(_ label: String, _ value: String) {
    print("  \(label.padding(toLength: 36, withPad: " ", startingAt: 0)) \(value)")
}
func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("multiemu-snapshot-spike: \(message)\n".utf8))
    exit(code)
}

var kernelURL: URL?
var initrdURL: URL?
var shellDelay = 10
var argv = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < argv.count {
    func next() -> String { index += 1; return index < argv.count ? argv[index] : "" }
    switch argv[index] {
    case "--kernel": kernelURL = URL(fileURLWithPath: next())
    case "--initrd": initrdURL = URL(fileURLWithPath: next())
    case "--shell-delay": shellDelay = Int(next()) ?? 10
    default: break
    }
    index += 1
}
guard let kernel = kernelURL else { fail("--kernel is required", code: 64) }
guard let qemuPath = ExternalToolProbe.resolve("qemu-system-aarch64") else {
    fail("qemu-system-aarch64 not found", code: 65)
}
guard let diskManager = VirtualDiskManager.locateDevelopmentTool() else {
    fail("qemu-img not found", code: 65)
}

let workingRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("multiemu-snapshot-\(UUID().uuidString)", isDirectory: true)
let store = VirtualDeviceStore(root: workingRoot, disks: diskManager)
let device: VirtualDeviceProfile
do {
    device = try store.create(VirtualDeviceProfile(
        name: "Snapshot device", imageIdentifier: "linux-fixture",
        guestArchitecture: .arm64, storageBytes: 4 * ByteCount.giB
    ))
} catch { fail("could not create the device: \(error)") }

let ramBefore = "RAM_BEFORE_\(UInt32.random(in: 100_000...999_999))"
let ramAfter = "RAM_AFTER_\(UInt32.random(in: 100_000...999_999))"
let diskBefore = "DISK_BEFORE_\(UInt32.random(in: 100_000...999_999))"
let diskAfter = "DISK_AFTER_\(UInt32.random(in: 100_000...999_999))"

print("multiemu-snapshot-spike")
row("qemu", qemuPath)
row("device", device.name)
print("")

// --- Start the guest through the real backend ---
let backend = QEMUBackend(executableURL: URL(fileURLWithPath: qemuPath))
let request = GuestStartRequest(
    guestArchitecture: .arm64,
    acceleration: .hardwareVirtualization,
    resources: GuestResourceRequest(memoryBytes: 2 * ByteCount.giB,
                                    storageBytes: device.storageBytes, vcpuCount: 4),
    kernelURL: kernel,
    initialRamdiskURL: initrdURL,
    kernelCommandLine: ["console=ttyAMA0", "console=tty0"],
    disks: store.writableDisks(for: device.id),
    displayMode: .attached(widthInPixels: 1280, heightInPixels: 800),
    network: .default,
    bootTimeout: .seconds(90)
)

// The backend runs the guest console on stdio, so answers come back as
// console events rather than in a file. Collecting them here also exercises the
// backend's own console plumbing.
final class ConsoleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}
let consoleBuffer = ConsoleBuffer()
let backendEvents = backend.events
let diagnostics = ConsoleBuffer()
let consoleCollector = Task {
    for await event in backendEvents {
        switch event {
        case .consoleLine(let line): consoleBuffer.append(line)
        case .backendMessage(let message): diagnostics.append("qemu: " + message)
        case .backendNotification(let name, let detail): diagnostics.append("note: \(name) \(detail)")
        case .stateChanged(let state): diagnostics.append("state: " + state.displayName)
        case .bootMilestone(let milestone): diagnostics.append("boot: " + milestone.kind.rawValue)
        }
    }
}

do { try await backend.start(request) } catch { fail("backend start failed: \(error)") }
row("backend", "started")

guard let control = await backend.controlChannelIfConnected() else {
    print("\n  backend diagnostics:")
    for line in diagnostics.text.split(separator: "\n").prefix(12) { print("    \(line)") }
    await backend.terminate()
    fail("no QMP control channel")
}

// Attach the display so the keyboard interface exists.
var descriptors: [Int32] = [0, 0]
guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
    await backend.terminate(); fail("socketpair failed: \(String(cString: strerror(errno)))")
}
do {
    try await control.sendFileDescriptor(descriptors[1], named: "displayfd")
    try await control.addClient(protocolName: "@dbus-display", fileDescriptorName: "displayfd")
} catch { await backend.terminate(); fail("display attach failed: \(error)") }
Darwin.close(descriptors[1])

let consoleConnection = DBusConnection(descriptor: descriptors[0], role: .client)
do { try await consoleConnection.authenticate() } catch {
    await backend.terminate(); fail("D-Bus auth failed: \(error)")
}
let display = QEMUDisplayClient(consoleConnection: consoleConnection)
let frames = display.events
do { try await display.registerListener() } catch {
    await backend.terminate(); fail("RegisterListener failed: \(error)")
}
let sink = Task { for await _ in frames {} }
let input = QEMUInputClient(connection: consoleConnection)
row("display + input", "attached")

let userdata = store.userdataURL(for: device.id)
func serialText() -> String { consoleBuffer.text }

row("waiting", "\(shellDelay)s for the guest shell")
try? await Task.sleep(for: .seconds(shellDelay))

// --- 1. Establish pre-snapshot state ---
try? await input.type("X=\(ramBefore)\n")
try? await input.type("echo \(diskBefore) > /dev/vda\n")
try? await input.type("sync\n")
try? await Task.sleep(for: .seconds(3))
row("state before snapshot", "RAM variable + disk marker set")

// --- 2. Capture ---
let clock = ContinuousClock()
let captureStarted = clock.now
let handle: SnapshotHandle
do { handle = try await backend.captureSnapshot(tag: "checkpoint") }
catch { await backend.terminate(); fail("captureSnapshot failed: \(error)") }
let captureDuration = clock.now - captureStarted
row("snapshot captured", String(format: "%.3f s", captureDuration.seconds))
row("machine state size", ByteCount.describe(handle.vmStateSizeBytes ?? 0))

// --- 3. Change both kinds of state ---
try? await input.type("X=\(ramAfter)\n")
try? await input.type("echo \(diskAfter) > /dev/vda\n")
try? await input.type("sync\n")
try? await Task.sleep(for: .seconds(2))
try? await input.type("echo CURRENT=$X > /dev/ttyAMA0\n")
try? await Task.sleep(for: .seconds(2))
let changedCorrectly = serialText().contains("CURRENT=\(ramAfter)")
row("state changed after snapshot", changedCorrectly ? "confirmed" : "NOT confirmed")

// --- 4. Restore ---
let restoreStarted = clock.now
do { try await backend.restoreSnapshot(tag: "checkpoint") }
catch { await backend.terminate(); fail("restoreSnapshot failed: \(error)") }
let restoreDuration = clock.now - restoreStarted
row("snapshot restored", String(format: "%.3f s", restoreDuration.seconds))

// --- 5. Read both kinds of state back ---
try? await Task.sleep(for: .seconds(2))
try? await input.type("echo RESTORED=$X > /dev/ttyAMA0\n")
try? await input.type("head -c 24 /dev/vda > /dev/ttyAMA0\n")
try? await Task.sleep(for: .seconds(3))

let finalText = serialText()
let ramRestored = finalText.contains("RESTORED=\(ramBefore)")
let ramNotStale = !finalText.contains("RESTORED=\(ramAfter)")
let diskRestored = finalText.contains(diskBefore)

// --- Listing and deletion ---
let listed = (try? await backend.listSnapshots()) ?? []
var deleted = false
do {
    try await backend.deleteSnapshot(tag: "checkpoint")
    deleted = ((try? await backend.listSnapshots()) ?? []).isEmpty
} catch { row("deleteSnapshot", "failed: \(error)") }

print("")
print("Results")
row("RAM state restored", ramRestored && ramNotStale
    ? "YES — the shell variable is the pre-snapshot value" : "NO")
row("disk state restored", diskRestored ? "YES — the pre-snapshot marker is back" : "NO")
row("snapshot listed", listed.contains { $0.tag == "checkpoint" } ? "YES" : "no")
row("snapshot deleted", deleted ? "YES" : "no")
row("capture duration", String(format: "%.3f s", captureDuration.seconds))
row("restore duration", String(format: "%.3f s", restoreDuration.seconds))
row("machine state size", ByteCount.describe(handle.vmStateSizeBytes ?? 0))
if let allocated = (try? diskManager.inspect(at: userdata))?.allocatedBytes() {
    row("disk allocated after all this", ByteCount.describe(allocated))
}

if !(ramRestored && diskRestored) {
    print("\n  serial tail:")
    for line in finalText.split(separator: "\n").suffix(8) { print("    \(line)") }
}

let passed = ramRestored && ramNotStale && diskRestored && deleted
print("")
print(passed
    ? "RESULT: PASS — snapshots capture and restore RAM and disk state."
    : "RESULT: FAIL — see above.")

sink.cancel()
consoleCollector.cancel()
await display.close()
await backend.terminate()
try? FileManager.default.removeItem(at: workingRoot)
exit(passed ? 0 : 2)
