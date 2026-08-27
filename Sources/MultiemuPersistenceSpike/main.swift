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

// multiemu-persistence-spike — Milestone 9 verification.
//
// Creates a virtual device, writes a marker into its userdata disk from inside
// the guest, shuts the guest down completely, boots a *second* guest against the
// same disk, and reads the marker back. Sparse allocation is measured on both
// sides of that.
//
// Uses the Milestone 6 keyboard path to drive the guest's shell, so the whole
// test runs unattended.

setvbuf(stdout, nil, _IONBF, 0)

func row(_ label: String, _ value: String) {
    print("  \(label.padding(toLength: 34, withPad: " ", startingAt: 0)) \(value)")
}
func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("multiemu-persistence-spike: \(message)\n".utf8))
    exit(code)
}

var kernelURL: URL?
var initrdURL: URL?
var workingRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("multiemu-persistence-\(UUID().uuidString)", isDirectory: true)
var shellDelay = 10
var argv = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < argv.count {
    func next() -> String { index += 1; return index < argv.count ? argv[index] : "" }
    switch argv[index] {
    case "--kernel": kernelURL = URL(fileURLWithPath: next())
    case "--initrd": initrdURL = URL(fileURLWithPath: next())
    case "--root": workingRoot = URL(fileURLWithPath: next())
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

let marker = "MULTIEMU_PERSIST_\(UInt32.random(in: 100_000...999_999))"

print("multiemu-persistence-spike")
row("qemu", qemuPath)
row("marker", marker)
print("")

// --- Create the device through the real store ---
let store = VirtualDeviceStore(root: workingRoot, disks: diskManager)
let device: VirtualDeviceProfile
do {
    device = try store.create(VirtualDeviceProfile(
        name: "Persistence device",
        imageIdentifier: "linux-fixture",
        guestArchitecture: .arm64,
        storageBytes: 32 * ByteCount.giB,
        display: .default
    ))
} catch {
    fail("could not create the device: \(error)")
}

let userdata = store.userdataURL(for: device.id)
func diskState() -> (logical: UInt64, allocated: UInt64) {
    let disk = (try? diskManager.inspect(at: userdata))
        ?? VirtualDisk(url: userdata, format: .qcow2, logicalSizeBytes: 0)
    return (disk.logicalSizeBytes, disk.allocatedBytes() ?? 0)
}

let created = diskState()
row("device", device.name)
row("userdata logical", ByteCount.describe(created.logical))
row("userdata allocated (fresh)", ByteCount.describe(created.allocated))
row("sparse on creation", created.allocated < created.logical / 2 ? "YES" : "NO")
print("")

// Top-level `var`s are main-actor isolated, so the values the run helper needs
// are captured as immutable locals first.
let resolvedInitrd = initrdURL
let resolvedShellDelay = shellDelay
let resolvedKernelPath = kernel.path
let resolvedQEMUPath = qemuPath
let resolvedUserdataPath = userdata.path

// --- One guest run, driving the shell over the keyboard interface ---
@discardableResult
/// Says where to look, and shows the end of it.
///
/// "the first guest run did not start" names the symptom and discards the one
/// artifact that explains it. The serial log is already on disk and its path is
/// already known here; a reader should not have to go and find it.
func startFailure(_ which: String, log: URL) -> String {
    let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    guard !text.isEmpty else {
        return "the \(which) guest run did not start, and wrote nothing to \(log.path) — "
            + "it did not get as far as the serial console"
    }
    let tail = text.split(separator: "\n").suffix(8).joined(separator: "\n  ")
    return "the \(which) guest run did not start. Last of \(log.path):\n  \(tail)"
}

func runGuest(label: String, serialLog: URL, commands: [String]) async -> Bool {
    try? FileManager.default.removeItem(at: serialLog)
    let socketPath = QMPClient.makeSocketPath(role: "persist")
    var arguments = [
        "-machine", "virt", "-accel", "hvf", "-cpu", "host",
        "-smp", "4", "-m", "2048",
        "-device", "virtio-gpu-pci,xres=1280,yres=800",
        "-device", "virtio-keyboard-pci",
        // The device under test: the same qcow2 file across both runs.
        "-drive", "file=\(resolvedUserdataPath),if=none,id=userdata,format=qcow2",
        "-device", "virtio-blk-pci,drive=userdata",
        "-display", "dbus,p2p=on",
        "-kernel", resolvedKernelPath,
        "-append", "console=ttyAMA0 console=tty0",
        "-serial", "file:\(serialLog.path)",
        "-qmp", "unix:\(socketPath),server=on,wait=off",
        "-no-reboot",
    ]
    if let initrd = resolvedInitrd { arguments += ["-initrd", initrd.path] }

    let qemu = QEMUProcess(executableURL: URL(fileURLWithPath: resolvedQEMUPath), arguments: arguments)
    // Capture the stream, not the process: QEMUProcess owns a Process and is
    // not Sendable, while the stream is.
    let qemuEvents = qemu.events
    let drain = Task { for await _ in qemuEvents {} }
    do { try qemu.start() } catch { print("  \(label): could not start QEMU: \(error)"); return false }

    let control = QMPClient()
    do { _ = try await control.connect(toSocketAt: socketPath, timeout: .seconds(15)) }
    catch { qemu.kill(); drain.cancel(); print("  \(label): QMP failed"); return false }

    var descriptors: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        qemu.kill(); drain.cancel(); return false
    }
    do {
        try await control.sendFileDescriptor(descriptors[1], named: "displayfd")
        try await control.addClient(protocolName: "@dbus-display", fileDescriptorName: "displayfd")
    } catch { qemu.kill(); drain.cancel(); print("  \(label): display attach failed"); return false }
    Darwin.close(descriptors[1])

    let console = DBusConnection(descriptor: descriptors[0], role: .client)
    do { try await console.authenticate() } catch { qemu.kill(); drain.cancel(); return false }
    let display = QEMUDisplayClient(consoleConnection: console)
    let frames = display.events
    do { try await display.registerListener() } catch { qemu.kill(); drain.cancel(); return false }
    let sink = Task { for await _ in frames {} }

    let input = QEMUInputClient(connection: console)
    try? await Task.sleep(for: .seconds(resolvedShellDelay))
    for command in commands {
        try? await input.type(command + "\n")
        try? await Task.sleep(for: .seconds(2))
    }
    // Give the guest time to flush before the machine disappears underneath it.
    try? await Task.sleep(for: .seconds(2))

    sink.cancel()
    await display.close()
    qemu.requestTermination()
    try? await Task.sleep(for: .milliseconds(400))
    qemu.kill()
    drain.cancel()
    return true
}

let firstLog = workingRoot.appendingPathComponent("run1-serial.log")
let secondLog = workingRoot.appendingPathComponent("run2-serial.log")

row("run 1", "writing the marker into the guest's disk")
let firstStarted = await runGuest(label: "run 1", serialLog: firstLog, commands: [
    "ls /dev/vd* > /dev/ttyAMA0",
    // Write straight to the block device: this initramfs has no mkfs, and what
    // is being tested is whether the qcow2 keeps guest writes, not whether a
    // filesystem does.
    "echo \(marker) > /dev/vda",
    "sync",
])
guard firstStarted else { fail(startFailure("first", log: firstLog)) }

let afterWrite = diskState()
row("userdata allocated (written)", ByteCount.describe(afterWrite.allocated))
row("grew on write", afterWrite.allocated > created.allocated ? "YES" : "no")
print("")

row("run 2", "a second guest reads the same disk back")
let secondStarted = await runGuest(label: "run 2", serialLog: secondLog, commands: [
    "head -c 40 /dev/vda > /dev/ttyAMA0",
])
guard secondStarted else { fail(startFailure("second", log: secondLog)) }

let secondText = (try? String(contentsOf: secondLog, encoding: .utf8)) ?? ""
let survived = secondText.contains(marker)
let afterRead = diskState()

print("")
print("Results")
row("marker written in run 1", (try? String(contentsOf: firstLog, encoding: .utf8))?.contains("/dev/vda") == true
     ? "block device present" : "block device not seen")
row("marker read back in run 2", survived ? "YES — data survived a full restart" : "NO")
row("logical size", ByteCount.describe(afterRead.logical))
row("allocated after both runs", ByteCount.describe(afterRead.allocated))
row("still sparse", afterRead.allocated < afterRead.logical / 2 ? "YES" : "NO")

// --- Factory reset must discard it ---
do { try store.factoryReset(device.id) } catch { fail("factory reset failed: \(error)") }
let afterReset = diskState()
row("allocated after factory reset", ByteCount.describe(afterReset.allocated))
let resetShrank = afterReset.allocated <= created.allocated
row("factory reset cleared data", resetShrank ? "YES" : "NO")
row("profile survived reset", (try? store.load(device.id))?.name == device.name ? "YES" : "NO")

if !survived {
    print("\n  run 2 serial tail:")
    for line in secondText.split(separator: "\n").suffix(6) { print("    \(line)") }
}

let passed = survived && afterRead.allocated < afterRead.logical / 2 && resetShrank
print("")
print(passed
    ? "RESULT: PASS — guest data persists across restart, the disk stays sparse, and factory reset clears it."
    : "RESULT: FAIL — see above.")

try? FileManager.default.removeItem(at: workingRoot)
exit(passed ? 0 : 2)
