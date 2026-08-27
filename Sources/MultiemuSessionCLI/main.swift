import Darwin
import Foundation
import MultiemuBackend
import MultiemuHost
import MultiemuLifecycle
import MultiemuQEMU
import MultiemuSupport

// multiemu-session — Milestone 3 verification tool.
//
// Drives a full guest lifecycle through the coordinator: preflight, start, boot,
// running, shutdown. The `crash` mode additionally kills the backend process
// from outside and checks that the session lands in `failed` with a usable
// reason, keeps its control state, and can restart.

struct Options {
    enum Mode: String { case run, crash }
    var mode: Mode = .run
    var kernel: URL?
    var initrd: URL?
    var architecture: GuestArchitecture = .arm64
    var acceleration: AccelerationMode = .hardwareVirtualization
    var vcpuCount = 2
    var memoryMiB: UInt64 = 2048
    var append: [String] = []
    /// Raw disk images attached in order, for booting a real Android image.
    var disks: [URL] = []
    /// How many virtio-console ports to give the guest.
    var consolePorts = 0
    /// Headless by default. An Android guest needs a GPU: with no display
    /// device there is no /dev/dri/card0, and SurfaceFlinger and zygote both
    /// abort with "couldn't find an OpenGL ES implementation".
    var display: GuestDisplayMode = .headless
    /// Which of those ports carries the sensors protocol, if any.
    var sensorsPort: Int?
    var androidConsolePort: Int?
    var qemuPath: String?
    var bootTimeoutSeconds = 60
    var showConsole = false
    var showHelp = false
}

let help = """
multiemu-session — drive a guest through the lifecycle coordinator

USAGE:
  multiemu-session --kernel <path> [--initrd <path>] [--mode run|crash] [options]

MODES:
  run     start, boot, report, graceful shutdown
  crash   start, boot, then SIGKILL the backend from outside and verify that
          the session reports the failure, keeps its control state, and restarts

OPTIONS:
  --kernel <path>        Kernel image (required).
  --initrd <path>        Initial ramdisk.
  --arch <arm64|x86_64>  Guest architecture. Default: arm64.
  --accel <hvf|tcg>      Accelerator. Default: hvf.
  --cpus <n>             vCPUs. Default: 2.
  --memory <MiB>         Guest memory. Default: 2048.
  --append <arg>         Kernel command line fragment. Repeatable.
  --qemu <path>          QEMU executable. Default: resolved from PATH.
  --boot-timeout <s>     Boot deadline. Default: 60.
  --console              Echo guest console lines.
  --disk <path>          Raw disk image, attached in order. Repeatable.
  --display <mode>       headless (default) or attached. An Android guest needs
                         attached: headless emits no GPU, and SurfaceFlinger and
                         zygote abort without one.
  --console-ports <n>    Give the guest n virtio-console ports (/dev/hvc0..).
  --sensors-port <n>     Serve the sensors protocol on that port index. An
                         Android guest whose sensors HAL goes unanswered never
                         reaches sys.boot_completed.
  --android-console-port <n>
                         The port index named by androidboot.console, where
                         Android starts a root shell. Given one, the emulator
                         stops guest services this host cannot support once the
                         guest is up - see GuestServiceQuiesce. Pass it only if
                         the kernel command line really names that port.
  -h, --help             Show this help.

EXIT CODES:
  0  scenario completed as expected
  2  scenario completed with an unexpected outcome
  64 bad usage
  65 prerequisite missing
"""

func parse(_ argv: [String]) throws -> Options {
    var options = Options()
    var index = 0
    func next(_ flag: String) throws -> String {
        index += 1
        guard index < argv.count else {
            throw MultiemuError.invalidConfiguration(field: flag, detail: "Expected a value.")
        }
        return argv[index]
    }
    while index < argv.count {
        switch argv[index] {
        case "--mode":
            let raw = try next("--mode")
            guard let mode = Options.Mode(rawValue: raw) else {
                throw MultiemuError.invalidConfiguration(field: "--mode", detail: "Expected run or crash, got '\(raw)'.")
            }
            options.mode = mode
        case "--kernel": options.kernel = URL(fileURLWithPath: try next("--kernel"))
        case "--initrd": options.initrd = URL(fileURLWithPath: try next("--initrd"))
        case "--arch":
            let raw = try next("--arch")
            guard let architecture = GuestArchitecture(rawValue: raw) else {
                throw MultiemuError.invalidConfiguration(field: "--arch", detail: "Expected arm64 or x86_64.")
            }
            options.architecture = architecture
        case "--accel":
            switch try next("--accel") {
            case "hvf": options.acceleration = .hardwareVirtualization
            case "tcg": options.acceleration = .softwareTranslation
            default: throw MultiemuError.invalidConfiguration(field: "--accel", detail: "Expected hvf or tcg.")
            }
        case "--cpus":
            guard let value = Int(try next("--cpus")), value >= 1 else {
                throw MultiemuError.invalidConfiguration(field: "--cpus", detail: "Expected a positive integer.")
            }
            options.vcpuCount = value
        case "--memory":
            guard let value = UInt64(try next("--memory")), value >= 64 else {
                throw MultiemuError.invalidConfiguration(field: "--memory", detail: "Expected MiB, at least 64.")
            }
            options.memoryMiB = value
        case "--append": options.append.append(try next("--append"))
        case "--disk": options.disks.append(URL(fileURLWithPath: try next("--disk")))
        case "--display":
            switch try next("--display") {
            case "headless": options.display = .headless
            case "attached": options.display = .attached(widthInPixels: 1920, heightInPixels: 1080)
            default:
                throw MultiemuError.invalidConfiguration(
                    field: "--display", detail: "Expected headless or attached.")
            }
        case "--console-ports":
            guard let value = Int(try next("--console-ports")), value >= 0 else {
                throw MultiemuError.invalidConfiguration(
                    field: "--console-ports", detail: "Expected a non-negative integer.")
            }
            options.consolePorts = value
        case "--sensors-port":
            guard let value = Int(try next("--sensors-port")), value >= 0 else {
                throw MultiemuError.invalidConfiguration(
                    field: "--sensors-port", detail: "Expected a non-negative integer.")
            }
            options.sensorsPort = value
        case "--android-console-port":
            guard let value = Int(try next("--android-console-port")), value >= 0 else {
                throw MultiemuError.invalidConfiguration(
                    field: "--android-console-port", detail: "Expected a non-negative integer.")
            }
            options.androidConsolePort = value
        case "--qemu": options.qemuPath = try next("--qemu")
        case "--boot-timeout":
            guard let value = Int(try next("--boot-timeout")), value > 0 else {
                throw MultiemuError.invalidConfiguration(field: "--boot-timeout", detail: "Expected a positive integer.")
            }
            options.bootTimeoutSeconds = value
        case "--console": options.showConsole = true
        case "-h", "--help": options.showHelp = true
        default:
            throw MultiemuError.invalidConfiguration(field: "arguments", detail: "Unrecognised option '\(argv[index])'.")
        }
        index += 1
    }
    return options
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("multiemu-session: \(message)\n".utf8))
    exit(code)
}

func heading(_ title: String) {
    print("")
    print("== \(title) " + String(repeating: "=", count: max(0, 60 - title.count)))
}

/// Finds the running QEMU process id from outside the application.
/// Used by the crash scenario so the kill is genuinely external.
func externalQEMUProcessIdentifier() -> Int32? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-n", "-f", "qemu-system"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

func waitForState(
    _ session: EmulatorSession,
    timeout: Duration,
    where predicate: @Sendable @escaping (GuestRunState) -> Bool
) async -> GuestRunState {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        let state = await session.state
        if predicate(state) { return state }
        try? await Task.sleep(for: .milliseconds(40))
    }
    return await session.state
}

// MARK: - Entry point

let options: Options
do {
    options = try parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as MultiemuError {
    fail("\(error.remediation)\n\n\(help)", code: 64)
} catch {
    fail("\(error)", code: 64)
}

if options.showHelp {
    print(help)
    exit(0)
}

guard let kernel = options.kernel else { fail("--kernel is required.\n\n\(help)", code: 64) }

let executableName = QEMUConfiguration.executableName(for: options.architecture)
guard let qemuPath = options.qemuPath ?? ExternalToolProbe.resolve(executableName) else {
    fail("\(executableName) not found on PATH. Install with `brew install qemu` or pass --qemu.", code: 65)
}
let qemuURL = URL(fileURLWithPath: qemuPath)

let host = HostCapabilityProbe(options: .init(runExternalToolVersionCommands: false)).collect()

let request = GuestStartRequest(
    guestArchitecture: options.architecture,
    acceleration: options.acceleration,
    resources: GuestResourceRequest(
        memoryBytes: options.memoryMiB * ByteCount.miB,
        storageBytes: 32 * ByteCount.giB,
        vcpuCount: options.vcpuCount
    ),
    kernelURL: kernel,
    initialRamdiskURL: options.initrd,
    kernelCommandLine: options.append,
    disks: options.disks.map {
        GuestDiskImage(url: $0, format: .raw, isReadOnly: false)
    },
    displayMode: options.display,
    consolePorts: try {
        // Index is the guest's /dev/hvcN number. Which one carries which
        // protocol is a property of the image, so it is stated here rather
        // than assumed by the backend.
        guard options.consolePorts > 0 else { return [] }
        var services: [Int: GuestConsolePort.Service] = [:]
        if let sensors = options.sensorsPort { services[sensors] = .sensors }
        if let console = options.androidConsolePort {
            // Rejected rather than resolved: two protocols on one port means
            // one of them was never going to be answered, and a dictionary
            // would drop the loser without a word.
            guard options.sensorsPort != console else {
                throw MultiemuError.invalidConfiguration(
                    field: "--android-console-port",
                    detail: "Port \(console) is already serving the sensors protocol.")
            }
            services[console] = .androidConsole
        }
        return try GuestConsolePort.bank(count: options.consolePorts, services: services)
    }(),
    bootTimeout: .seconds(options.bootTimeoutSeconds)
)

let session = EmulatorSession(
    configuration: .init(deviceName: "Milestone 3 device", startRequest: request),
    host: host,
    backendFactory: { QEMUBackend(executableURL: qemuURL) }
)

// Print session events as they arrive.
let printer = Task { [showConsole = options.showConsole] in
    for await event in session.events {
        switch event {
        case .stateChanged(let state):       print("  [state]    \(state.displayName)")
        case .bootMilestone(let milestone):  print(String(format: "  [boot]     %8.3f s  %@", milestone.elapsed.seconds, milestone.kind.rawValue))
        case .preflightWarning(let warning): print("  [warn]     \(warning.replacingOccurrences(of: "\n", with: " "))")
        case .notice(let notice):            print("  [notice]   \(notice.prefix(160))")
        case .consoleLine(let line):         if showConsole { print("  |          \(line)") }
        }
    }
}

print("multiemu-session")
print("  host       \(host.cpu.brand) (\(host.cpu.architecture.rawValue)), macOS \(host.operatingSystem.productVersion)")
print("  guest      \(options.architecture.displayName), \(options.acceleration.displayName)")
print("  qemu       \(qemuPath)")
print("  mode       \(options.mode.rawValue)")

var exitCode: Int32 = 0

heading("preflight")
let checks = await session.preflight()
print("  verdict    \(checks.isAllowed ? "allowed" : "REFUSED")")
for error in checks.errors { print("  error      \(error.remediation.replacingOccurrences(of: "\n", with: " "))") }
if !checks.isAllowed { fail("Preflight refused the configuration.", code: 65) }

heading("start")
do {
    try await session.start()
} catch {
    fail("start failed: \(error)", code: 2)
}

let running = await waitForState(session, timeout: .seconds(options.bootTimeoutSeconds + 10)) { state in
    if case .running = state { return true }
    if case .failed = state { return true }
    return false
}

guard case .running = running else {
    heading("result")
    print(await session.diagnosticsSummary())
    fail("guest did not reach running: \(running.displayName)", code: 2)
}

// Prove the control channel is live by asking QEMU itself.
if let backend = await session.currentBackendForDiagnostics() as? QEMUBackend,
   let control = await backend.controlChannelIfConnected() {
    if let status = try? await control.queryStatus() {
        print("  [qmp]      query-status -> \(status)")
    }
}

switch options.mode {

case .run:
    heading("graceful shutdown")
    await session.requestShutdown(timeout: .seconds(20))
    let stopped = await waitForState(session, timeout: .seconds(30)) { !$0.isActive }
    print("  final      \(stopped.displayName)")
    if stopped.isActive { exitCode = 2 }

case .crash:
    heading("external kill (SIGKILL from outside the application)")
    guard let pid = externalQEMUProcessIdentifier() else {
        fail("could not locate the backend process to kill", code: 2)
    }
    print("  killing    pid \(pid)")
    kill(pid, SIGKILL)

    let failed = await waitForState(session, timeout: .seconds(20)) { $0.failure != nil }
    guard let failure = failed.failure else {
        heading("result")
        print(await session.diagnosticsSummary())
        fail("session did not report a failure after the backend was killed", code: 2)
    }

    heading("failure was captured")
    print("  kind       \(failure.kind.rawValue)")
    print("  summary    \(failure.summary)")
    print("  exit code  \(failure.backendExitCode.map(String.init) ?? "n/a")")
    print("  console    \(failure.consoleTail.count) lines retained")

    heading("control state survived the backend")
    print(await session.diagnosticsSummary())

    let runsBefore = await session.runCount
    heading("restart")
    do {
        try await session.restart()
    } catch {
        fail("restart failed: \(error)", code: 2)
    }
    let recovered = await waitForState(session, timeout: .seconds(options.bootTimeoutSeconds + 10)) { state in
        if case .running = state { return true }
        if case .failed = state { return true }
        return false
    }
    let runsAfter = await session.runCount
    print("  runs       \(runsBefore) -> \(runsAfter)")
    print("  state      \(recovered.displayName)")
    if case .running = recovered {} else { exitCode = 2 }

    heading("shutdown")
    await session.requestShutdown(timeout: .seconds(20))
    _ = await waitForState(session, timeout: .seconds(30)) { !$0.isActive }
    print("  final      \(await session.state.displayName)")
}

heading("summary")
print(await session.diagnosticsSummary())
printer.cancel()
exit(exitCode)
