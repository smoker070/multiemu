import Darwin
import Foundation
import MultiemuBackend
import MultiemuDBus
import MultiemuGraphics
import MultiemuADB
import MultiemuGuestServices
import MultiemuInput
import MultiemuQEMU
import MultiemuSupport

// Measures the metrics in docs/PERFORMANCE-METHODOLOGY.md against a real guest
// and writes the report the methodology asks for.
//
// The QEMU command line comes from `QEMUCommandBuilder`, the same builder the
// product uses, and never from a hand-written argument list. That is not
// fastidiousness: an earlier hand-rolled command line omitted `virtio-rng`, the
// guest blocked on entropy, and the resulting cold-boot figure was 2.5x the
// product's — a number that described a configuration nobody ships.

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
USAGE:
  multiemu-perf --kernel <path> --initrd <path> --disk <path>
                [--seconds <n>] [--settle <n>] [--out <dir>]
                [--console-ports <n>] [--sensors-port <n>]

Boots a guest, measures it, and writes a Markdown report.

OPTIONS:
  --seconds <n>        Frame and CPU sampling window. Default 60.
  --settle <n>         Seconds to wait after boot before sampling. Default 120,
                       as the methodology requires for idle CPU.
  --idle-seconds <n>   Idle-CPU sampling window. Default 300, per the
                       methodology. Sampled with no workload running.
  --out <dir>          Report directory. Default: reports/
  --adb-port <n>       Forward host 127.0.0.1:<n> to the guest's adbd, set the
                       guest up for it, and drive the workload over ADB. Without
                       this the workload is synthetic touches, which a lock
                       screen barely repaints.
  --workload           Drive a scripted scroll during sampling. Without it the
                       guest is idle, which produces sporadic frames and cannot
                       evaluate the pacing target at all.
  --max-runtime <n>    Hard wall-clock ceiling for the whole run, in seconds.
                       On expiry the guest is killed and the harness exits 3.
                       Defaults to twice the sum of the phase budgets, floored
                       at 300. A backstop for stalls that the per-phase
                       deadlines cannot catch, not a phase budget itself.
  -h, --help           Show this help.

EXIT CODES:
  0  measured, report written
  2  the guest did not boot
  3  the run exceeded --max-runtime and was killed
  64 bad usage
"""

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments.contains("-h") || arguments.contains("--help") {
    print(usage)
    exit(arguments.isEmpty ? 64 : 0)
}

// Declared before the first `fail()` can run, and deliberately optional: the
// usage errors below happen before there is a guest to adopt, and an exit path
// that cannot state whether it has one would either trap or leak.
var deadline: RunDeadline?

@MainActor func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("multiemu-perf: \(message)\n".utf8))
    // Never `exit()` alone. QEMU is a child, not a dependent: leaving it behind
    // orphans four spinning vCPUs onto launchd, where nothing will ever reap
    // them. Every early return from here on ends the guest too.
    deadline?.killGuest()
    deadline?.finish()
    exit(code)
}

@MainActor func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

guard let kernelPath = option("--kernel") else { fail("--kernel is required.", code: 64) }
guard let diskPath = option("--disk") else { fail("--disk is required.", code: 64) }
let initrdPath = option("--initrd")
let sampleSeconds = Double(option("--seconds") ?? "60") ?? 60
let settleSeconds = Double(option("--settle") ?? "120") ?? 120
let idleSeconds = Double(option("--idle-seconds") ?? "300") ?? 300
let reportDirectory = URL(fileURLWithPath: option("--out") ?? "reports", isDirectory: true)
let consolePortCount = Int(option("--console-ports") ?? "0") ?? 0
let sensorsPort = option("--sensors-port").flatMap(Int.init)
let drivesWorkload = arguments.contains("--workload")
// With an ADB port the workload is driven inside the guest instead of by
// synthetic touches. That matters: a scripted touch on a lock screen repaints
// almost nothing, so the frame figures describe an idle screen. ADB can
// dismiss the keyguard and scroll a real list.
let adbPort = option("--adb-port").flatMap(Int.init)

/// How long the guest gets to reach `sys.boot_completed`.
let bootCeilingSeconds: Double = 180

// The ceiling starts before QEMU does, because a stall in the display
// handshake holds the machine exactly as hard as one in the workload, and that
// handshake happens before there is a pid to blame it on.
let runDeadline = RunDeadline(
    limit: Double(option("--max-runtime") ?? "") ?? RunDeadline.defaultLimit(
        bootCeiling: bootCeilingSeconds,
        settleSeconds: settleSeconds,
        idleSeconds: idleSeconds,
        sampleSeconds: sampleSeconds),
    onExpiry: { expiry in
        // Written rather than `print`ed, and `_exit` rather than `exit`: this
        // runs on the watchdog's own thread precisely because the rest of the
        // process is presumed wedged, so it must not wait on a lock or an
        // atexit handler that the wedged side may be holding.
        let message = "multiemu-perf: exceeded the \(Int(expiry.limit)) s ceiling while "
            + "\(expiry.phase). Killing the guest and giving up.\n"
            + "No report was written. Treat the phase above as where it stalled, "
            + "or raise --max-runtime if this guest is legitimately slower.\n"
        FileHandle.standardError.write(Data(message.utf8))
        if expiry.guestPID > 0 { Darwin.kill(expiry.guestPID, SIGKILL) }
        _exit(3)
    })
deadline = runDeadline
runDeadline.start()

/// A value written on one thread and read on another.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
}

// MARK: - Statistics

// Statistics come from `MultiemuSupport.PerformanceStatistics`, which has
// tests. They were local to this file first; a percentile that is off by one
// rank yields a plausible number and a wrong conclusion, and the report is the
// only thing that would have shown it.
func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
    PerformanceStatistics.percentile(sorted, fraction)
}

func mean(_ values: [Double]) -> Double {
    PerformanceStatistics.mean(values)
}

/// One host process's share of a core, sampled over time.
struct ProcessSamples {
    var name: String
    var cpuPercent: [Double] = []
    var residentBytes: [Double] = []
    /// Accumulated CPU seconds at the previous sample, to difference against.
    var lastCPUSeconds: Double?
}

/// Parses `ps` TIME: `MM:SS.ss`, `HH:MM:SS`, or `D-HH:MM:SS`.
///
/// Accumulated CPU time differenced between samples, never `ps -o %cpu`: on
/// macOS that column is an average over the process's whole lifetime, so a
/// guest that worked hard while booting keeps a high figure forever and an
/// "idle" measurement silently reports the boot instead. The first version of
/// this harness made exactly that mistake and produced 58% for an idle guest.
func cpuSeconds(_ field: String) -> Double? {
    var text = field
    var days = 0.0
    if let dash = text.firstIndex(of: "-") {
        days = Double(text[text.startIndex..<dash]) ?? 0
        text = String(text[text.index(after: dash)...])
    }
    let parts = text.split(separator: ":").map(String.init)
    guard !parts.isEmpty else { return nil }
    let numbers = parts.compactMap(Double.init)
    guard numbers.count == parts.count else { return nil }
    let withinDay: Double
    switch numbers.count {
    case 3: withinDay = numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
    case 2: withinDay = numbers[0] * 60 + numbers[1]
    case 1: withinDay = numbers[0]
    default: return nil
    }
    return days * 86400 + withinDay
}

// MARK: - Boot

let qemuPath = "/opt/homebrew/bin/qemu-system-aarch64"
guard FileManager.default.isExecutableFile(atPath: qemuPath) else {
    fail("QEMU is not installed at \(qemuPath).")
}

let controlSocket = QMPClient.makeSocketPath(role: "perf")
var consolePorts: [QEMUConfiguration.ConsolePort] = []
var sensorsSocket: String?
// Port 1 carries the guest's own console shell when ADB setup is needed. It is
// a bring-up channel — a root shell in the guest — and is only opened when the
// caller asks for ADB.
var setupConsoleSocket: String?
if consolePortCount > 0 {
    let path = sensorsPort.map { _ in QMPClient.makeSocketPath(role: "hvcsensors") }
    sensorsSocket = path
    // Allocated whenever the bank has room, not only for ADB: the guest-service
    // quiesce below is product behaviour that every measurement must include,
    // and a harness that measured a guest the product would have quiesced
    // would be reporting a configuration nobody ships.
    if consolePortCount > 1 { setupConsoleSocket = QMPClient.makeSocketPath(role: "hvcsetup") }
    consolePorts = (0..<consolePortCount).map { index in
        // Only the sensors port and the setup console need sockets.
        if index == sensorsPort, let path {
            return .init(backend: .unixSocket(path: path))
        }
        if index == 1, let setup = setupConsoleSocket {
            return .init(backend: .unixSocket(path: setup))
        }
        return .init(backend: .null)
    }
}

let configuration = QEMUConfiguration(
    executableURL: URL(fileURLWithPath: qemuPath),
    guestArchitecture: .arm64,
    acceleration: .hardwareVirtualization,
    vcpuCount: 4,
    memoryBytes: 4 * ByteCount.giB,
    kernelURL: URL(fileURLWithPath: kernelPath),
    initialRamdiskURL: initrdPath.map { URL(fileURLWithPath: $0) },
    kernelCommandLine: arguments.enumerated().compactMap { index, value in
        value == "--append" && index + 1 < arguments.count ? arguments[index + 1] : nil
    },
    drives: [.init(id: "disk0", url: URL(fileURLWithPath: diskPath), format: .raw, readOnly: false)],
    portForwards: adbPort.map { [.init(hostPort: $0, guestPort: 5555)] } ?? [],
    includeNetworkDevice: adbPort != nil,
    display: .dbusDisplay(peerToPeer: true, widthInPixels: 1920, heightInPixels: 1920),
    includeInputDevices: true,
    serial: .stdio,
    consolePorts: consolePorts,
    qmpSocketPath: controlSocket)

let qemuArguments: [String]
do { qemuArguments = try QEMUCommandBuilder.arguments(for: configuration) }
catch { fail("the command line is invalid: \(error)") }

let qemu = QEMUProcess(executableURL: URL(fileURLWithPath: qemuPath), arguments: qemuArguments)
let qemuEvents = qemu.events

/// Boot is detected from the guest's own console, the way the boot probe does
/// it — never by asking a shell, which participates in the boot and perturbs
/// the thing being measured.
actor BootWatch {
    private var completedAt: ContinuousClock.Instant?
    private let started = ContinuousClock.now

    func noteLine(_ line: String) {
        guard completedAt == nil,
              line.contains("processing action (sys.boot_completed=1)") else { return }
        completedAt = ContinuousClock.now
    }

    var bootSeconds: Double? {
        completedAt.map { started.duration(to: $0).seconds }
    }
}

let bootWatch = BootWatch()
let drain = Task {
    for await event in qemuEvents {
        if case let .consoleLine(line) = event { await bootWatch.noteLine(line) }
    }
}

do { try qemu.start() } catch { fail("could not start QEMU: \(error)") }
runDeadline.adopt(guestPID: qemu.processIdentifier)

// The guest's sensors HAL blocks until this answers, and an unanswered port
// stalls the boot outright — the failure this harness hit on its first run.
var sensorsResponder: GuestConsoleResponder?
if let sensorsSocket {
    let responder = GuestConsoleResponder(socketPath: sensorsSocket, service: SensorsService())
    do {
        try await responder.start()
        sensorsResponder = responder
    } catch {
        fail("could not serve the sensors port: \(error)")
    }
}

@MainActor func shutDown(_ code: Int32) -> Never {
    qemu.kill()
    drain.cancel()
    runDeadline.finish()
    exit(code)
}

print("booting…")
runDeadline.enter("waiting for the guest to boot")
let bootDeadline = ContinuousClock.now.advanced(by: .seconds(bootCeilingSeconds))
var coldBootSeconds: Double?
while ContinuousClock.now < bootDeadline {
    if let seconds = await bootWatch.bootSeconds { coldBootSeconds = seconds; break }
    try? await Task.sleep(for: .milliseconds(200))
}
guard let coldBootSeconds else {
    fail("the guest did not reach sys.boot_completed within \(Int(bootCeilingSeconds)) s.")
}
print(String(format: "cold boot: %.3f s", coldBootSeconds))

// MARK: - Quiesce

// What `QEMUBackend` does on its own boot-completed transition, done here
// because this harness drives QEMU directly. Two Cuttlefish services cannot
// work on this host and init restarts them about once a second forever; left
// alone they are the largest single item in idle host CPU.
//
// On its own thread: `perform` blocks on console reads, and a blocking call
// inside a `Task` starves the cooperative pool — the failure that killed an
// earlier run of this very harness.
var quiesceSummary: String?
if let setup = setupConsoleSocket {
    runDeadline.enter("quiescing guest services")
    let outcome: GuestServiceQuiesce.Outcome? = await withCheckedContinuation { continuation in
        let thread = Thread {
            let shell = GuestConsoleShell(socketPath: setup)
            continuation.resume(returning: try? shell.withSession { GuestServiceQuiesce.perform(over: $0) })
        }
        thread.name = "multiemu.guest-quiesce"
        thread.start()
    }
    quiesceSummary = outcome?.summary ?? "console unreachable — nothing quiesced"
    print("guest services: \(quiesceSummary ?? "")")
}

// MARK: - Display channel

runDeadline.enter("opening the display channel")
let control = QMPClient()
do { _ = try await control.connect(toSocketAt: controlSocket, timeout: .seconds(20)) }
catch { shutDown(2) }

var descriptors: [Int32] = [0, 0]
guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { shutDown(2) }
do {
    try await control.sendFileDescriptor(descriptors[1], named: "displayfd")
    try await control.addClient(protocolName: "@dbus-display", fileDescriptorName: "displayfd")
} catch {
    Darwin.close(descriptors[0]); Darwin.close(descriptors[1])
    fail("display channel refused: \(error)")
}
Darwin.close(descriptors[1])

let connection = DBusConnection(descriptor: descriptors[0], role: .client)
do { try await connection.authenticate() } catch { fail("D-Bus handshake failed: \(error)") }
let display = QEMUDisplayClient(consoleConnection: connection)
let frameEvents = display.events
do { try await display.registerListener() } catch { fail("no display listener: \(error)") }
let input = QEMUInputClient(connection: connection)

// Apply the product's default mode. The framebuffer is allocated square so
// rotation can swap the axes, and the intended mode is applied over D-Bus
// afterwards — the emulator does both, and a harness that does only the first
// measures 1920x1920, which is 78% more pixels than the 1920x1080 the product
// actually presents. A frame rate for a mode nobody ships is not the metric.
do {
    try await input.setUIInfo(width: 1920, height: 1080)
    print("requested the product default mode: 1920 x 1080")
} catch {
    print("could not set the display mode: \(error)")
}

/// Frame arrival times. The interval between them is what the pacing target is
/// about; a mean rate alone cannot show stutter.
actor FrameClock {
    private var instants: [ContinuousClock.Instant] = []
    private var collecting = false
    /// The guest's real mode, learned from a frame.
    ///
    /// Not `consoleGeometry()`: that reports QEMU's console size, which is the
    /// square boot allocation (1920x1920) rather than the mode the guest chose
    /// (1920x1080). Scripting a gesture against the square put every touch
    /// below the bottom of the screen.
    private(set) var frameSize: CGSize?

    func begin() { collecting = true; instants.removeAll() }

    func note(width: Int, height: Int) {
        if frameSize == nil { frameSize = CGSize(width: width, height: height) }
        if collecting { instants.append(.now) }
    }

    /// Intervals in milliseconds.
    func intervals() -> [Double] {
        PerformanceStatistics.intervalsInMilliseconds(instants)
    }
}

let frameClock = FrameClock()
let frameReader = Task {
    for await event in frameEvents {
        switch event {
        case let .scanout(frame):
            await frameClock.note(width: frame.width, height: frame.height)
        case let .update(_, _, frame):
            await frameClock.note(width: frame.width, height: frame.height)
        default: break
        }
    }
}

// MARK: - Settle, then sample

runDeadline.enter("settling")
print("settling for \(Int(settleSeconds)) s…")
try? await Task.sleep(for: .seconds(settleSeconds))

// Two phases, because they measure different things and the methodology
// asks for different conditions. An earlier version sampled CPU *while* the
// workload ran and labelled the result "idle" — a load measurement wearing the
// wrong name, which is why it read 53%.

// --- Phase 1: idle CPU ---
runDeadline.enter("sampling idle CPU")
print("sampling idle CPU for \(Int(idleSeconds)) s…")
var processSamples: [String: ProcessSamples] = [:]
var lastSampleAt: ContinuousClock.Instant?
var sampleCount = 0

@MainActor func sampleProcesses() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-Ao", "pid=,time=,rss=,comm="]
    let pipe = Pipe()
    process.standardOutput = pipe
    let sampledAt = ContinuousClock.now
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let elapsed = lastSampleAt.map { $0.duration(to: sampledAt).seconds } ?? 0
    lastSampleAt = sampledAt

    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 4 else { continue }
        let leaf = (fields[3...].joined(separator: " ") as NSString).lastPathComponent
        // The harness itself is the instrument, not the product: counting its
        // own `ps` spawns toward "host CPU consumed by Multiemu" would inflate
        // the figure by roughly two points.
        guard leaf.hasPrefix("qemu-system") || leaf == "Multiemu"
                || (leaf.hasPrefix("multiemu") && leaf != "multiemu-perf")
        else { continue }
        guard let accumulated = cpuSeconds(String(fields[1])),
              let rssKB = Double(fields[2]) else { continue }

        var samples = processSamples[leaf] ?? ProcessSamples(name: leaf)
        if let previous = samples.lastCPUSeconds, elapsed > 0 {
            samples.cpuPercent.append((accumulated - previous) / elapsed * 100)
        }
        samples.lastCPUSeconds = accumulated
        samples.residentBytes.append(rssKB * 1024)
        processSamples[leaf] = samples
    }
    sampleCount += 1
}

let idleStarted = ContinuousClock.now
while idleStarted.duration(to: .now).seconds < idleSeconds {
    sampleProcesses()
    try? await Task.sleep(for: .seconds(1))
}

// --- Between phases: make ADB reachable, if asked ---
//
// The sequence and its verification live in `MultiemuGuestServices`, and the
// client is the one the product ships. An earlier version of this file carried
// its own copy of both — a hand-written command list and a private ADB client —
// which is how a harness ends up measuring a path nobody else runs.
var adb: ADBDevice?
if let adbPort, let setup = setupConsoleSocket {
    runDeadline.enter("enabling ADB in the guest")
    print("enabling ADB in the guest…")

    // On its own thread: `withSession` blocks for several seconds, and this is
    // the main actor. Blocking it would stall the display listener that is
    // still draining frame events.
    let shell = GuestConsoleShell(socketPath: setup)
    let outcome: GuestADBEnablement.Outcome? = await withCheckedContinuation { continuation in
        let thread = Thread {
            continuation.resume(
                returning: try? shell.withSession { GuestADBEnablement.perform(over: $0) })
        }
        thread.name = "multiemu.perf.adb-enable"
        thread.start()
    }
    print("  \(outcome?.summary ?? "the guest console did not answer")")

    let device = ADBDevice(host: "127.0.0.1", port: adbPort, timeout: 20)
    let release: String? = await withCheckedContinuation { continuation in
        let thread = Thread {
            continuation.resume(returning: try? device.shell("getprop ro.build.version.release")
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        thread.name = "multiemu.perf.adb-probe"
        thread.start()
    }
    if let release, !release.isEmpty {
        print("ADB reachable — Android \(release)")
        adb = device
    } else {
        print("ADB did not come up; the workload will fall back to synthetic touches")
    }
}

/// `ADBDevice.shell` blocks, and a blocking call in a `Task` occupies a
/// cooperative thread for its whole duration. Looping it there starved the
/// executor so the sampling sleep never resumed and the harness died without
/// writing a report — the same mistake as reading a socket inside an actor.
final class WorkloadDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var stopping = false
    private var swipes = 0

    var swipeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return swipes
    }

    private var shouldStop: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopping
    }

    func stop() {
        lock.lock(); stopping = true; lock.unlock()
    }

    func start(adb: ADBDevice?, input: QEMUInputClient, size: CGSize) {
        let thread = Thread { [self] in
            let x = Int(size.width / 2)
            let top = Int(size.height * 0.25)
            let bottom = Int(size.height * 0.75)
            while !shouldStop {
                guard let adb else { break }
                // Android's own injection path, so it lands on whatever window
                // has focus rather than at a coordinate this process guessed.
                _ = try? adb.shell("input swipe \(x) \(bottom) \(x) \(top) 120")
                _ = try? adb.shell("input swipe \(x) \(top) \(x) \(bottom) 120")
                lock.lock(); swipes += 2; lock.unlock()
            }
        }
        thread.name = "com.multiemu.perf.workload"
        thread.stackSize = 512 * 1024
        thread.start()
    }
}

// --- Input probe: does anything we send reach the guest's input stack? ---
//
// `MULTITOUCH-ACCEPTANCE-IS-NOT-EVIDENCE-OF-DELIVERY` in docs/VERIFY.md says
// QEMU accepts SendEvent whether or not a device exists and never errors, so
// nothing observed from the host side is proof. This asks Android instead:
// `getevent` prints every event the guest kernel actually receives.
if arguments.contains("--input-probe"), let adb {
    runDeadline.enter("probing input")
    print("")
    print("=== input probe ===")

    let probeSize = await frameClock.frameSize ?? CGSize(width: 1920, height: 1080)
    let console = await input.consoleGeometry()
    print("frame \(Int(probeSize.width))x\(Int(probeSize.height)); console "
        + "\(console.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unknown")")

    // The keyguard first. In current Android the lock screen is drawn by the
    // NotificationShade window, so a probe that skips this taps the lock screen
    // and reports that nothing happened.
    _ = try? adb.shell("input keyevent 82")
    _ = try? adb.shell("wm dismiss-keyguard")
    try? await Task.sleep(for: .seconds(2))
    _ = try? adb.shell("input keyevent KEYCODE_HOME")
    try? await Task.sleep(for: .seconds(3))

    // A real target, from the guest's own view hierarchy, so the tap is aimed
    // at something that is actually there.
    _ = try? adb.shell("uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1")
    let dump = (try? adb.shell("cat /data/local/tmp/ui.xml 2>/dev/null")) ?? ""
    var iconCentre = CGPoint(x: probeSize.width / 2, y: probeSize.height / 2)
    var iconLabel = "(screen centre — no node found)"
    for node in dump.components(separatedBy: "<node").dropFirst() {
        guard node.contains("clickable=\"true\""),
              let boundsRange = node.range(of: #"bounds="\[\d+,\d+\]\[\d+,\d+\]""#,
                                           options: .regularExpression) else { continue }
        let n = node[boundsRange].split(whereSeparator: { !"0123456789".contains($0) })
                                 .compactMap { Double($0) }
        guard n.count == 4, n[2] > n[0], n[3] > n[1],
              n[2] - n[0] < probeSize.width * 0.6 else { continue }
        iconCentre = CGPoint(x: (n[0] + n[2]) / 2, y: (n[1] + n[3]) / 2)
        if let d = node.range(of: #"content-desc="[^"]*""#, options: .regularExpression) {
            iconLabel = String(node[d])
        }
        break
    }
    print("target: \(iconLabel) at \(Int(iconCentre.x)),\(Int(iconCentre.y))")

    func focus() -> String {
        let out = (try? adb.shell("dumpsys window 2>/dev/null | grep -m1 mCurrentFocus")) ?? ""
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "mCurrentFocus=Window{", with: "")
    }

    // Every device at once, so the routing of each half of a gesture is visible
    // rather than inferred. Bounded by time: a bound in events never returns.
    let captured = LockedBox<String>("")
    let listener = Thread {
        captured.set((try? adb.shell("timeout 40 getevent -lt 2>&1")) ?? "(failed)")
    }
    listener.start()
    try? await Task.sleep(for: .seconds(2))

    let focusBefore = focus()

    // Three taps, not one. QEMU's `end` releases the tracking id but never
    // sends `BTN_TOUCH` false, so the button stays down in the guest; if
    // Android needed it, the first tap would work and every later one would be
    // swallowed as a duplicate. That is a failure a single-tap check cannot see.
    var translator = PointerTouchTranslator()
    var focusAfterTouch = focusBefore
    for attempt in 1...3 {
        print(">>> TOUCH tap \(attempt)")
        _ = try? adb.shell("input keyevent KEYCODE_HOME")
        try? await Task.sleep(for: .seconds(2))
        let start = focus()
        do { try await input.perform(translator.pressed(.left, at: iconCentre)) }
        catch { print("    down refused: \(error)") }
        try? await Task.sleep(for: .milliseconds(120))
        do { try await input.perform(translator.released(.left, at: iconCentre)) }
        catch { print("    up refused: \(error)") }
        try? await Task.sleep(for: .seconds(3))
        focusAfterTouch = focus()
        print("    tap \(attempt): \(focusAfterTouch == start ? "NO REACTION" : "reacted") -> \(focusAfterTouch)")
    }
    _ = try? adb.shell("input keyevent KEYCODE_HOME")
    try? await Task.sleep(for: .seconds(2))

    print(">>> POINTER tap")
    try? await input.moveAbsolute(to: iconCentre)
    try? await Task.sleep(for: .milliseconds(60))
    try? await input.press(QEMUPointerButton.left)
    try? await Task.sleep(for: .milliseconds(120))
    try? await input.release(QEMUPointerButton.left)
    try? await Task.sleep(for: .seconds(3))
    let focusAfterPointer = focus()

    for _ in 0..<45 where !listener.isFinished { try? await Task.sleep(for: .seconds(1)) }
    print("full event trace:")
    for line in captured.get().split(separator: "\n") where !line.contains("add device")
                                                          && !line.contains("name:") {
        print("    \(line)")
    }
    print("focus before:        \(focusBefore)")
    print("focus after TOUCH:   \(focusAfterTouch)  \(focusAfterTouch == focusBefore ? "SAME" : "CHANGED")")
    print("focus after POINTER: \(focusAfterPointer)  \(focusAfterPointer == focusAfterTouch ? "SAME" : "CHANGED")")
    print("=== end input probe ===")
    print("")
}

// The mode the guest actually chose, learned from a frame rather than asked of
// QEMU. `consoleGeometry()` reports the square boot allocation (1920x1920), and
// scripting a gesture against that put every touch below the bottom of the
// screen.
let guestSize = await frameClock.frameSize ?? CGSize(width: 1920, height: 1080)
print(String(format: "guest display: %.0f x %.0f", guestSize.width, guestSize.height))

// Get past the keyguard and onto something that redraws. Measuring a lock
// screen produced 424 frames covering 19% of the window, which is not a frame
// rate; the same run driven onto Settings produced 2607 covering all of it.
//
// On a thread, like every other blocking ADB call here.
if let adb {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let thread = Thread {
            _ = try? adb.shell("input keyevent 82")
            _ = try? adb.shell("wm dismiss-keyguard")
            _ = try? adb.shell("am start -a android.settings.SETTINGS")
            continuation.resume()
        }
        thread.name = "multiemu.perf.foreground"
        thread.start()
    }
    try? await Task.sleep(for: .seconds(2))
}

print("sampling frames for \(Int(sampleSeconds)) s…\(drivesWorkload ? " (scroll workload)" : " (idle)")")
runDeadline.enter("sampling frames under the workload")
await frameClock.begin()

let driver = WorkloadDriver()
if drivesWorkload, adb != nil {
    driver.start(adb: adb, input: input, size: guestSize)
} else if drivesWorkload {
    print("no ADB: falling back to synthetic touches, which a lock screen barely repaints")
}

try? await Task.sleep(for: .seconds(sampleSeconds))
driver.stop()

let intervals = await frameClock.intervals()
frameReader.cancel()

// MARK: - Report

runDeadline.enter("writing the report")
let sortedIntervals = intervals.sorted()
let p50 = percentile(sortedIntervals, 0.50)
let p95 = percentile(sortedIntervals, 0.95)
let p99 = percentile(sortedIntervals, 0.99)
let longest = sortedIntervals.last ?? 0
let observedFPS = intervals.isEmpty ? 0 : 1000 / mean(intervals)
let over33 = intervals.filter { $0 > 33.3 }.count
let over16 = intervals.filter { $0 > 16.7 }.count

/// What share of the sampling window actually contained frames.
///
/// Frames x p50 against the window length. A guest that draws nothing for most
/// of the window is not being measured for throughput — it is being measured
/// for having nothing to draw, and reporting that as a frame-rate failure
/// blames the renderer for an idle screen.
let frameCoverage: Double = {
    guard !intervals.isEmpty, sampleSeconds > 0 else { return 0 }
    return min(1, Double(intervals.count) * p50 / 1000 / sampleSeconds)
}()

let pacingVerdict: String = {
    guard frameCoverage >= 0.5 else {
        return """
            **No verdict — the workload did not drive rendering.** Frames covered only \
            \(formatted(frameCoverage * 100, 0))% of the sampling window, so the guest spent \
            most of it drawing nothing at all. When frames did flow they arrived every \
            \(formatted(p50)) ms (\(formatted(1000 / max(p50, 0.001), 1)) FPS) at p50 and \
            \(formatted(p95)) ms (\(formatted(1000 / max(p95, 0.001), 1)) FPS) at p95, which is \
            the useful signal here. The scripted scroll lands on a lock screen with almost \
            nothing to repaint; measuring sustained throughput needs a workload that keeps \
            the guest rendering continuously.
            """
    }
    guard drivesWorkload else {
        return """
            **No verdict.** These frames come from an idle guest, which updates only             when something on screen changes. The pacing target is defined against a             scripted workload; run with `--workload` to evaluate it. The numbers above             describe idleness, not throughput.
            """
    }
    let pacingPassed = PerformanceStatistics.pacingIsAcceptable(p50: p50, p99: p99)
    let ratePassed = observedFPS >= 30
    let pacing = "Pacing: p99 " + formatted(p99) + " ms against 2x p50 "
        + formatted(2 * p50) + " ms — " + (pacingPassed ? "**PASS**" : "**FAIL**") + "."
    let rate = "Sustained rate: " + formatted(observedFPS, 1)
        + " FPS against >= 30 — " + (ratePassed ? "**PASS**" : "**FAIL**") + "."
    return pacing + "\n\n" + rate
}()

let totalCPU = processSamples.values.reduce(into: [Double]()) { totals, samples in
    for (index, value) in samples.cpuPercent.enumerated() {
        if index < totals.count { totals[index] += value } else { totals.append(value) }
    }
}
let meanCPU = mean(totalCPU)
let p95CPU = percentile(totalCPU.sorted(), 0.95)
let totalRSS = processSamples.values.reduce(0.0) { $0 + ($1.residentBytes.max() ?? 0) }

func formatted(_ value: Double, _ places: Int = 2) -> String {
    String(format: "%.\(places)f", value)
}

var report = """
# Performance baseline

Generated by `multiemu-perf`. The QEMU command line came from
`QEMUCommandBuilder`, so these describe the configuration the product ships.

Guest services: \(quiesceSummary ?? "not attempted — no console port configured").
Stopping services this host cannot support is what `QEMUBackend` does on its own
boot-completed transition; a measurement without it describes a guest the
product would not have left in that state.

| Metric | Value | Target | Verdict |
| --- | --- | --- | --- |
| Cold boot to `sys.boot_completed` | \(formatted(coldBootSeconds, 3)) s | <= 45 s (60 s max) | \(coldBootSeconds <= 45 ? "**PASS**" : "**FAIL**") |
| Idle host CPU, all processes | mean \(formatted(meanCPU, 1))% of one core, p95 \(formatted(p95CPU, 1))% | < 10% | \(meanCPU < 10 ? "**PASS**" : "**FAIL**") |
| Peak resident memory, all processes | \(ByteCount.describe(UInt64(totalRSS))) | none stated | — |

## Frame rate and pacing

Sampled for \(Int(sampleSeconds)) s after a \(Int(settleSeconds)) s settle, from frames
delivered over the D-Bus display channel. Guest mode as actually rendered:
\(Int(guestSize.width))x\(Int(guestSize.height)) — `SetUIInfo` advises, and the guest decides,
so this may differ from the mode requested.

"""

if intervals.isEmpty {
    report += """
    **No frames were delivered during the sampling window.** An idle Android
    guest with its screen settled produces no new scanouts, so this is what an
    untouched device looks like rather than a failure to present. Measuring the
    pacing target needs the scripted workload the methodology asks for, which
    needs guest-side input — see the input-latency note below.

    """
} else {
    report += """
    | Statistic | Value |
    | --- | --- |
    | Frames observed | \(intervals.count + 1) |
    | Mean rate | \(formatted(observedFPS, 1)) FPS |
    | p50 frame interval | \(formatted(p50)) ms |
    | p95 frame interval | \(formatted(p95)) ms |
    | p99 frame interval | \(formatted(p99)) ms |
    | Longest interval | \(formatted(longest)) ms |
    | Intervals over 33.3 ms | \(over33) |
    | Intervals over 16.7 ms | \(over16) |

    \(pacingVerdict)

    """
}

report += """
Workload: \(driver.swipeCount) swipes driven over ADB during sampling.

## Per-process attribution

| Process | Mean CPU (% of one core) | p95 CPU | Peak RSS |
| --- | --- | --- | --- |

"""
for samples in processSamples.values.sorted(by: { mean($0.cpuPercent) > mean($1.cpuPercent) }) {
    report += "| `\(samples.name)` | \(formatted(mean(samples.cpuPercent), 1)) | "
        + "\(formatted(percentile(samples.cpuPercent.sorted(), 0.95), 1)) | "
        + "\(ByteCount.describe(UInt64(samples.residentBytes.max() ?? 0))) |\n"
}

report += """

Samples: \(sampleCount), one per second.

## Not measured here

- **Input latency** — needs a guest-side timestamp to correlate against, which
  needs input delivery verified inside the guest.
- **APK installation** — measured by Milestone 10 against package size, not by
  this harness, because it is a transfer rate rather than a steady-state cost.
- **Disk I/O and snapshot duration** — measured by their own milestones' spikes,
  not by this harness.
"""

try? FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
let reportURL = reportDirectory.appendingPathComponent("performance-\(stamp).md")
do { try report.write(to: reportURL, atomically: true, encoding: .utf8) }
catch { fail("could not write the report: \(error)") }

print("")
print(report)
print("written to \(reportURL.path)")

await sensorsResponder?.stop()
qemu.kill()
drain.cancel()
runDeadline.finish()
exit(0)
