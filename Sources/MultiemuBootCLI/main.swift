import Darwin
import Foundation
import MultiemuBackend
import MultiemuHost
import MultiemuQEMU
import MultiemuSupport

// multiemu-boot — Milestone 2 boot experiment.
//
// Boots a Linux kernel under QEMU with the selected accelerator, watches the
// guest serial console, and reports a timestamped boot timeline. This is the
// instrument that produces the cold-boot numbers in the milestone report; it is
// not a backend and it is not used by the application.

struct Options {
    var kernel: URL?
    var initrd: URL?
    var architecture: GuestArchitecture = .arm64
    var acceleration: AccelerationMode = .hardwareVirtualization
    var vcpuCount = 2
    var memoryBytes: UInt64 = 2 * ByteCount.giB
    var appendArguments: [String] = []
    var qemuPath: String?
    var timeoutSeconds = 120
    var echoConsole = false
    var extraArguments: [String] = []
    var showHelp = false
}

let help = """
multiemu-boot — boot a Linux kernel under QEMU and time the result

USAGE:
  multiemu-boot --kernel <path> [--initrd <path>] [options]

OPTIONS:
  --kernel <path>        Kernel image (required).
  --initrd <path>        Initial ramdisk.
  --arch <arm64|x86_64>  Guest architecture. Default: arm64.
  --accel <hvf|tcg>      Accelerator. Default: hvf.
  --cpus <n>             vCPU count. Default: 2.
  --memory <MiB>         Guest memory in MiB. Default: 2048.
  --append <args>        Kernel command line. Repeatable.
  --qemu <path>          QEMU executable. Default: resolved from PATH.
  --timeout <seconds>    Give up after this long. Default: 120.
  --extra <arg>          Extra argument appended verbatim to the QEMU
                         command line. Repeatable. For experiments only.
  --echo                 Echo every guest console line.
  -h, --help             Show this help.

EXIT CODES:
  0  Boot reached a terminal success milestone.
  2  Boot failed (kernel panic or root mount failure).
  3  Timed out before any terminal milestone.
  64 Bad usage.
  65 QEMU could not be found or started.
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
        case "--kernel": options.kernel = URL(fileURLWithPath: try next("--kernel"))
        case "--initrd": options.initrd = URL(fileURLWithPath: try next("--initrd"))
        case "--arch":
            let raw = try next("--arch")
            guard let architecture = GuestArchitecture(rawValue: raw) else {
                throw MultiemuError.invalidConfiguration(field: "--arch", detail: "Expected arm64 or x86_64, got '\(raw)'.")
            }
            options.architecture = architecture
        case "--accel":
            let raw = try next("--accel")
            switch raw {
            case "hvf": options.acceleration = .hardwareVirtualization
            case "tcg": options.acceleration = .softwareTranslation
            default: throw MultiemuError.invalidConfiguration(field: "--accel", detail: "Expected hvf or tcg, got '\(raw)'.")
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
            options.memoryBytes = value * ByteCount.miB
        case "--append": options.appendArguments.append(try next("--append"))
        case "--qemu": options.qemuPath = try next("--qemu")
        case "--timeout":
            guard let value = Int(try next("--timeout")), value > 0 else {
                throw MultiemuError.invalidConfiguration(field: "--timeout", detail: "Expected a positive integer.")
            }
            options.timeoutSeconds = value
        case "--extra": options.extraArguments.append(try next("--extra"))
        case "--echo": options.echoConsole = true
        case "-h", "--help": options.showHelp = true
        default:
            throw MultiemuError.invalidConfiguration(field: "arguments", detail: "Unrecognised option '\(argv[index])'.")
        }
        index += 1
    }
    return options
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("multiemu-boot: \(message)\n".utf8))
    exit(code)
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

guard let kernel = options.kernel else {
    fail("--kernel is required.\n\n\(help)", code: 64)
}
guard FileManager.default.fileExists(atPath: kernel.path) else {
    fail("Kernel not found at \(kernel.path)", code: 65)
}
if let initrd = options.initrd, !FileManager.default.fileExists(atPath: initrd.path) {
    fail("Initial ramdisk not found at \(initrd.path)", code: 65)
}

// Resolve QEMU. Milestone 2 accepts a developer QEMU from PATH; shipping builds
// resolve a bundled, signed helper instead.
let executableName = QEMUConfiguration.executableName(for: options.architecture)
guard let qemuPath = options.qemuPath ?? ExternalToolProbe.resolve(executableName) else {
    fail("""
        \(executableName) was not found on PATH.
        Install a development QEMU with `brew install qemu`, or pass --qemu <path>.
        """, code: 65)
}

// Sanity-check the accelerator choice against the host before spawning anything.
let host = HostCapabilityProbe(options: .init(runExternalToolVersionCommands: false)).collect()
let selection = BackendSelector.select(
    guestArchitecture: options.architecture,
    input: BackendSelectionInput(host: host)
)

let configuration = QEMUConfiguration(
    executableURL: URL(fileURLWithPath: qemuPath),
    guestArchitecture: options.architecture,
    acceleration: options.acceleration,
    vcpuCount: options.vcpuCount,
    memoryBytes: options.memoryBytes,
    kernelURL: kernel,
    initialRamdiskURL: options.initrd,
    kernelCommandLine: options.appendArguments,
    display: .none,
    serial: .stdio,
    extraArguments: options.extraArguments
)

let arguments: [String]
do {
    arguments = try QEMUCommandBuilder.arguments(for: configuration)
} catch let error as MultiemuError {
    fail(error.remediation, code: 64)
}

print("multiemu-boot")
print("  host            \(host.cpu.brand) (\(host.cpu.architecture.rawValue)), macOS \(host.operatingSystem.productVersion)")
print("  guest           \(options.architecture.displayName)")
print("  accelerator     \(options.acceleration.displayName)")
print("  selector says   \(selection.supportLevel.rawValue) via \(selection.recommendedBackend?.displayName ?? "none")")
for warning in selection.warnings {
    print("  WARNING         \(warning.replacingOccurrences(of: "\n", with: " "))")
}
print("  qemu            \(qemuPath)")
print("  command         \((try? QEMUCommandBuilder.displayCommandLine(for: configuration)) ?? "?")")
print("")

let qemu = QEMUProcess(executableURL: configuration.executableURL, arguments: arguments)
let trace = PerformanceTrace(category: .boot)
let signpostState = trace.begin(SignpostName.guestColdBoot)
let clock = ContinuousClock()
let launchStarted = clock.now

do {
    try qemu.start()
} catch {
    fail("Could not start QEMU: \(error)", code: 65)
}

var probe = GuestBootProbe()
var backendMessages: [String] = []
var exitInformation: (code: Int32, reason: String)?

let deadline = launchStarted.advanced(by: .seconds(options.timeoutSeconds))

// A watchdog task terminates QEMU if no terminal milestone arrives in time, so
// the experiment always produces a report instead of hanging.
let watchdog = Task {
    try? await Task.sleep(until: deadline, clock: ContinuousClock())
    if !Task.isCancelled {
        qemu.requestTermination()
    }
}

for await event in qemu.events {
    switch event {
    case .consoleLine(let line):
        if options.echoConsole { print("  | \(line)") }
        if let milestone = probe.consume(line: line, elapsed: clock.now - launchStarted) {
            print(String(format: "  %8.3f s  %@", milestone.elapsed.seconds, milestone.kind.rawValue))
            if milestone.kind.isTerminalSuccess || milestone.kind.isTerminalFailure {
                qemu.requestTermination()
            }
        }
    case .backendMessage(let message):
        backendMessages.append(message)
    case .exited(let code, let reason):
        exitInformation = (code, reason)
    }
}

watchdog.cancel()
trace.end(SignpostName.guestColdBoot, signpostState)
let totalElapsed = clock.now - launchStarted

print("")
print("Boot timeline")
print(probe.milestones.isEmpty ? "  (no milestones recognised)" : probe.timeline())
print("")
print("Result")
print("  total wall time  \(String(format: "%.3f s", totalElapsed.seconds))")
if let exitInformation {
    print("  qemu exit        \(exitInformation.reason) \(exitInformation.code)")
}
if !backendMessages.isEmpty {
    print("  qemu stderr:")
    for message in backendMessages.prefix(20) { print("    \(message)") }
}

if probe.hasSucceeded {
    print("  verdict          PASS — guest reached userspace")
    exit(0)
} else if probe.hasFailed {
    print("  verdict          FAIL — guest boot failed")
    exit(2)
} else {
    print("  verdict          TIMEOUT — no terminal milestone within \(options.timeoutSeconds)s")
    exit(3)
}
