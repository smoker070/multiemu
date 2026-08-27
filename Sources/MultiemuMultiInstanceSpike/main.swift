import Darwin
import Foundation
import MultiemuBackend
import MultiemuConfiguration
import MultiemuDisks
import MultiemuHost
import MultiemuLifecycle
import MultiemuQEMU
import MultiemuSupport

// multiemu-multi-instance-spike — Milestone 18 verification.
//
// Starts several virtual devices AT THE SAME TIME through the production path
// (VirtualDeviceStore -> EmulatorSession -> QEMUBackend) and checks the three
// things the milestone claims:
//
//   1. every device runs under its own helper process,
//   2. a read-only image is SHARED between them, not copied,
//   3. admission accounts for devices that are already running.
//
// The third is the decisive one, and it is checked by trying to admit a device
// that would not fit — a run where everything is admitted proves nothing about
// whether the accounting exists.

setvbuf(stdout, nil, _IONBF, 0)

func row(_ label: String, _ value: String) {
    print("  \(label.padding(toLength: 42, withPad: " ", startingAt: 0)) \(value)")
}
func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("multiemu-multi-instance-spike: \(message)\n".utf8))
    exit(code)
}

var kernelURL: URL?
var initrdURL: URL?
var deviceCount = 2
var memoryPerDeviceGiB: UInt64 = 2
var startConcurrently = false
var workingRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("multiemu-multi-\(UUID().uuidString)", isDirectory: true)

var argv = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < argv.count {
    func next() -> String { index += 1; return index < argv.count ? argv[index] : "" }
    switch argv[index] {
    case "--kernel": kernelURL = URL(fileURLWithPath: next())
    case "--initrd": initrdURL = URL(fileURLWithPath: next())
    case "--devices": deviceCount = Int(next()) ?? 2
    case "--memory-gib": memoryPerDeviceGiB = UInt64(next()) ?? 2
    case "--root": workingRoot = URL(fileURLWithPath: next())
    case "--concurrent": startConcurrently = true
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

let host = HostCapabilityProbe(options: .init(runExternalToolVersionCommands: false)).collect()

print("multiemu-multi-instance-spike")
row("qemu", qemuPath)
row("host", "\(host.cpu.brand) · \(host.cpu.logicalCores) logical cores")
row("host memory", ByteCount.describe(host.memory.physicalBytes))
row("memory budget for guests", ByteCount.describe(
    ResourceValidator.maximumAllowedGuestMemory(physicalBytes: host.memory.physicalBytes)))
row("devices requested", "\(deviceCount) × \(memoryPerDeviceGiB) GiB")
print("")

// --- The shared, read-only image every device attaches ---
//
// One file. Read-only openers do not exclude one another, which is what lets
// devices share an image instead of each holding a copy.
let sharedImage = workingRoot.appendingPathComponent("shared-system.img")
do {
    try FileManager.default.createDirectory(at: workingRoot, withIntermediateDirectories: true)
    try diskManager.create(at: sharedImage, format: .raw, sizeBytes: 256 * ByteCount.miB)
} catch {
    fail("could not create the shared image: \(error)")
}

/// Tracks what the devices started so far have claimed.
///
/// This is the spike's stand-in for `AppModel`: something that knows which
/// devices are running, so a starting device can be admitted against reality
/// rather than against an empty host.
actor RunningLedger {
    private var resources: [UUID: GuestResourceRequest] = [:]
    private var ports: [UUID: Int] = [:]

    /// Validates and claims in ONE step.
    ///
    /// An actor method with no `await` inside is a critical section, which is
    /// what admission needs. Checking and claiming as two steps fails in both
    /// orders: check-then-claim admits two devices that each read a total
    /// excluding the other, and claim-then-check makes every device weigh
    /// itself against its siblings' claims so that a simultaneous start refuses
    /// everyone.
    func admit(
        _ id: UUID,
        _ request: GuestResourceRequest,
        port: Int,
        host: HostCapabilities
    ) -> ResourceValidationResult {
        let result = ResourceValidator.validate(request, host: host, committed: committed(excluding: id))
        if result.isAllowed {
            resources[id] = request
            ports[id] = port
        }
        return result
    }

    func claim(_ id: UUID, _ request: GuestResourceRequest, port: Int) {
        resources[id] = request
        ports[id] = port
    }
    func release(_ id: UUID) {
        resources[id] = nil
        ports[id] = nil
    }
    /// What everything *other than* `excluding` has claimed.
    ///
    /// A device claims before it is validated, so that a sibling starting at the
    /// same moment cannot be admitted against a total that ignores it. It must
    /// then be left out of its own admission, or every device refuses itself.
    func committed(excluding excluded: UUID? = nil) -> CommittedResources {
        let others = resources.filter { $0.key != excluded }
        return CommittedResources.summing(
            Array(others.values),
            hostPorts: Set(ports.filter { $0.key != excluded }.values)
        )
    }
    var deviceCount: Int { resources.count }
}

let ledger = RunningLedger()
let store = VirtualDeviceStore(root: workingRoot, disks: diskManager)
let resolvedKernel = kernel
let resolvedInitrd = initrdURL
let resolvedQEMU = URL(fileURLWithPath: qemuPath)
let resolvedShared = sharedImage
let resolvedHost = host
let resolvedMemory = memoryPerDeviceGiB

struct RunningDevice {
    var profile: VirtualDeviceProfile
    var session: EmulatorSession
    var hostPort: Int
}

func makeStartRequest(for profile: VirtualDeviceProfile, hostPort: Int) -> GuestStartRequest {
    var network = GuestNetworkConfiguration.default
    network.portForwards = [
        .init(label: "spike", hostPort: hostPort, guestPort: 5555, networkProtocol: .tcp)
    ]
    return GuestStartRequest(
        guestArchitecture: .arm64,
        acceleration: .hardwareVirtualization,
        resources: profile.resources,
        kernelURL: resolvedKernel,
        initialRamdiskURL: resolvedInitrd,
        kernelCommandLine: ["console=ttyAMA0"],
        disks: [
            // Shared, read-only: the same file for every device.
            GuestDiskImage(url: resolvedShared, format: .raw, isReadOnly: true),
            // Private and writable: this device's own disk.
            GuestDiskImage(url: store.userdataURL(for: profile.id), format: .qcow2, isReadOnly: false),
        ],
        network: network,
        bootTimeout: .seconds(90)
    )
}

func makeSession(for profile: VirtualDeviceProfile, hostPort: Int, deviceID: UUID) -> EmulatorSession {
    EmulatorSession(
        configuration: .init(deviceName: profile.name, startRequest: makeStartRequest(for: profile, hostPort: hostPort)),
        host: resolvedHost,
        committedResources: { await ledger.committed(excluding: deviceID) },
        backendFactory: { QEMUBackend(executableURL: resolvedQEMU) }
    )
}

// --- Start every device, one after another, each admitted against the ones
//     already running ---

var running: [RunningDevice] = []
var startFailures: [String] = []
var pending: [(ordinal: Int, profile: VirtualDeviceProfile, port: Int)] = []

print("Starting devices")
for ordinal in 1...deviceCount {
    let profile: VirtualDeviceProfile
    do {
        profile = try store.create(VirtualDeviceProfile(
            name: "Device \(ordinal)",
            imageIdentifier: "linux-fixture",
            guestArchitecture: .arm64,
            memoryBytes: resolvedMemory * ByteCount.giB,
            storageBytes: 8 * ByteCount.giB,
            vcpuCount: 2,
            display: .default
        ))
    } catch {
        fail("could not create device \(ordinal): \(error)")
    }

    let port: Int
    do { port = try HostPortAllocator.allocate() } catch {
        fail("no free loopback port for device \(ordinal): \(error)")
    }

    pending.append((ordinal: ordinal, profile: profile, port: port))
}

/// Starts one device, claiming its resources before it can suspend.
///
/// The claim goes in first on purpose. Preflight runs several awaits deep, so
/// claiming only on success would let two devices starting at the same moment
/// each be admitted against a total that excluded the other.
func startDevice(ordinal: Int, profile: VirtualDeviceProfile, port: Int) async -> RunningDevice? {
    let admission = await ledger.admit(
        profile.id, profile.resources, port: port, host: resolvedHost)
    guard admission.isAllowed else {
        let reason = admission.errors.map(\.remediation).joined(separator: "; ")
        await MainActor.run { startFailures.append("device \(ordinal): \(reason)") }
        return nil
    }
    let session = makeSession(for: profile, hostPort: port, deviceID: profile.id)
    do {
        try await session.start()
        return RunningDevice(profile: profile, session: session, hostPort: port)
    } catch {
        await ledger.release(profile.id)
        let reason = (error as? MultiemuError)?.remediation ?? String(describing: error)
        await MainActor.run { startFailures.append("device \(ordinal): \(reason)") }
        return nil
    }
}

if startConcurrently {
    // Every device starts in the same instant. If admission had a check-then-act
    // window, this is where more memory than the budget gets admitted.
    row("mode", "concurrent — all \(pending.count) devices start at once")
    running = await withTaskGroup(of: RunningDevice?.self) { group in
        for item in pending {
            group.addTask { await startDevice(ordinal: item.ordinal, profile: item.profile, port: item.port) }
        }
        var started: [RunningDevice] = []
        for await result in group { if let result { started.append(result) } }
        return started
    }
    for device in running.sorted(by: { $0.hostPort < $1.hostPort }) {
        row("started", "\(device.profile.name) · port \(device.hostPort)")
    }
} else {
    row("mode", "sequential")
    for item in pending {
        let before = await ledger.committed()
        if let device = await startDevice(ordinal: item.ordinal, profile: item.profile, port: item.port) {
            running.append(device)
            row("device \(item.ordinal)",
                "started · port \(item.port) · \(before.deviceCount) already running")
        } else {
            row("device \(item.ordinal)", "REFUSED")
        }
    }
}

// Whatever the ordering, the devices that ARE running must fit the budget. This
// is the invariant a check-then-act race breaks.
let admittedMemory = running.reduce(UInt64(0)) { $0 + $1.profile.memoryBytes }
let memoryBudget = ResourceValidator.maximumAllowedGuestMemory(
    physicalBytes: resolvedHost.memory.physicalBytes)
print("")
row("admitted memory", ByteCount.describe(admittedMemory))
row("budget", ByteCount.describe(memoryBudget))
let withinBudget = admittedMemory <= memoryBudget
row("within budget", withinBudget ? "PASS" : "FAIL — admission over-committed the host")
print("")

// --- 1. Separate helper processes ---

print("1. Each device runs under its own helper process")
var pids: [Int32] = []
for device in running {
    if let backend = await device.session.currentBackendForDiagnostics(),
       let pid = await (backend as? QEMUBackend)?.processIdentifier {
        pids.append(pid)
    }
}
row("running devices", "\(running.count)")
row("distinct helper PIDs", "\(Set(pids).count) of \(pids.count) — \(pids.map(String.init).joined(separator: ", "))")
let separateProcesses = pids.count == running.count && Set(pids).count == pids.count
row("verdict", separateProcesses ? "PASS" : "FAIL")
print("")

// --- 2. The read-only image is shared, not copied ---

print("2. The read-only image is shared, not copied")
var attachedReadOnly: [URL] = []
for device in running {
    let request = await device.session.configuration.startRequest
    attachedReadOnly += request.disks.filter(\.isReadOnly).map(\.url)
}
let inodes = Set(attachedReadOnly.compactMap {
    (try? FileManager.default.attributesOfItem(atPath: $0.path)[.systemFileNumber]) as? Int
})
row("read-only disks attached", "\(attachedReadOnly.count)")
row("distinct files behind them", "\(inodes.count)")
row("shared image size", ByteCount.describe(
    UInt64((try? FileManager.default.attributesOfItem(atPath: resolvedShared.path)[.size] as? Int) ?? 0)))
let shared = !running.isEmpty && inodes.count == 1 && attachedReadOnly.count == running.count
row("verdict", shared ? "PASS — one file, \(attachedReadOnly.count) devices" : "FAIL")
print("")

// --- 3. Forwarded ports are distinct and loopback-only ---

print("3. Forwarded ports are distinct, and bound to loopback only")
let claimedPorts = running.map(\.hostPort)
row("ports", claimedPorts.map(String.init).joined(separator: ", "))
row("distinct", "\(Set(claimedPorts).count) of \(claimedPorts.count)")
var wildcardBindings: [String] = []
for port in claimedPorts {
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    probe.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
    let pipe = Pipe()
    probe.standardOutput = pipe
    probe.standardError = FileHandle.nullDevice
    try? probe.run()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    probe.waitUntilExit()
    for line in text.split(whereSeparator: \.isNewline) where line.contains("LISTEN") {
        // A forward bound to * would expose a guest to the whole network.
        if line.contains("*:\(port)") { wildcardBindings.append(String(line)) }
    }
}
row("wildcard bindings", wildcardBindings.isEmpty ? "none" : "\(wildcardBindings.count) — EXPOSED")
let portsOK = Set(claimedPorts).count == claimedPorts.count && wildcardBindings.isEmpty
row("verdict", portsOK ? "PASS" : "FAIL")
print("")

// --- 4. Admission accounts for what is already running ---
//
// The decisive check. A device sized to fit an empty host but NOT to fit
// alongside the running ones must be refused, and refused for that reason.

print("4. Admission accounts for devices already running")
let budget = ResourceValidator.maximumAllowedGuestMemory(physicalBytes: resolvedHost.memory.physicalBytes)
let committedNow = await ledger.committed()
let remaining = budget > committedNow.memoryBytes ? budget - committedNow.memoryBytes : 0
// Ask for everything still free, plus a gigabyte: fits an idle Mac, cannot fit now.
let oversizedBytes = remaining + ByteCount.giB
row("budget", ByteCount.describe(budget))
row("committed by running devices", ByteCount.describe(committedNow.memoryBytes))
row("remaining", ByteCount.describe(remaining))
row("about to request", ByteCount.describe(oversizedBytes))

let probeRequest = GuestResourceRequest(
    memoryBytes: oversizedBytes, storageBytes: 8 * ByteCount.giB, vcpuCount: 2)
let onAnEmptyHost = ResourceValidator.validate(probeRequest, host: resolvedHost, committed: .none)
let alongsideRunning = ResourceValidator.validate(probeRequest, host: resolvedHost, committed: committedNow)

row("allowed on an empty host", onAnEmptyHost.isAllowed ? "yes" : "no")
row("allowed alongside running", alongsideRunning.isAllowed ? "yes" : "no")
let saidBudgetExhausted = alongsideRunning.errors.contains {
    if case .hostBudgetExhausted = $0 { return true } else { return false }
}
if let first = alongsideRunning.errors.first {
    for line in first.remediation.split(whereSeparator: \.isNewline) {
        print("      \(line.trimmingCharacters(in: .whitespaces))")
    }
}
// Only meaningful if the same request WOULD have been admitted alone; otherwise
// the refusal says nothing about multi-instance accounting.
let admissionOK = onAnEmptyHost.isAllowed && !alongsideRunning.isAllowed && saidBudgetExhausted
row("verdict", admissionOK ? "PASS" : "FAIL")
print("")

// --- 5. A port another device holds is refused too ---

print("5. A port another device already forwards is refused")
var clashing = GuestNetworkConfiguration.default
if let taken = claimedPorts.first {
    clashing.portForwards = [.init(label: "clash", hostPort: taken, guestPort: 5555, networkProtocol: .tcp)]
}
let clashProblems = clashing.problems(claimedHostPorts: committedNow.hostPorts)
let freshProblems = clashing.problems(claimedHostPorts: [])
row("as a lone device", freshProblems.isEmpty ? "accepted" : "rejected")
row("alongside running", clashProblems.isEmpty ? "accepted" : "rejected")
let portAdmissionOK = freshProblems.isEmpty && !clashProblems.isEmpty
row("verdict", portAdmissionOK ? "PASS" : "FAIL")
print("")

// --- Shut everything down ---

print("Shutting down")
for device in running {
    await device.session.terminate()
    await ledger.release(device.profile.id)
}
row("devices stopped", "\(running.count)")
row("still committed", "\(await ledger.committed().deviceCount) devices")
print("")

let checks: [(String, Bool)] = [
    ("separate helper processes", separateProcesses),
    ("read-only image shared, not copied", shared),
    ("distinct loopback-only ports", portsOK),
    ("admission accounts for running devices", admissionOK),
    ("port clash refused against running devices", portAdmissionOK),
    ("admitted devices fit the host budget", withinBudget),
]
print("Result")
for (name, ok) in checks { row(name, ok ? "PASS" : "FAIL") }
if !startFailures.isEmpty {
    print("")
    print("  devices that did not start:")
    for failure in startFailures { print("    \(failure)") }
}

try? FileManager.default.removeItem(at: workingRoot)

// The exit code follows the CHECKS, not the number of devices that started.
//
// Requiring every requested device to start was wrong: this spike is run with
// deliberate over-subscription (`--devices 6` against a smaller budget), where
// refusing some of them is the correct behaviour being demonstrated. The checks
// already encode what correctness means, including that admitted devices fit
// the budget — and total starvation, where nothing starts, fails them anyway
// because there is then no shared image and no separate process to observe.
//
// The one thing the checks cannot see is a run where nothing was even
// attempted, so that is asserted separately.
let startedAnything = !running.isEmpty
if !startedAnything { print("  no device started at all") }
exit(checks.allSatisfy(\.1) && startedAnything ? 0 : 1)
