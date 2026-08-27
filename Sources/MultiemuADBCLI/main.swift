import Foundation
import MultiemuADB

// The first-party ADB client, as a command.
//
// It exists so the client that ships is the one that gets used: a protocol
// implementation exercised only by its own tests drifts from the guest it is
// meant to talk to. Everything here goes through `MultiemuADB`, the same code
// the application links.
//
// Not a drop-in replacement for Google's `adb`. There is no server, no device
// discovery, no port 5037 — a Multiemu guest's port is known because Multiemu
// forwarded it.

let usage = """
USAGE:
  multiemu-adb --port <n> <command>

COMMANDS:
  info                      Print the device banner adbd answers CNXN with.
  shell <command...>        Run one command and print its output.
  push <local> <remote>     Copy a host file into the guest.
  pull <remote> <local>     Copy a guest file to the host.
  stat <remote>             Print mode, size and modification time.
  install <apk>             Validate, stage and install an APK.
  uninstall <package>       Remove a package for the current user.
  launch <package>          Start the package's launcher activity.

OPTIONS:
  --port <n>     Host port forwarded to the guest's adbd. Required.
  --key <path>   RSA key for guests that demand authentication. Created if
                 absent. Omit for userdebug guests, which do not ask.
  --timeout <s>  Per-operation timeout in seconds. Default 60.
  -h, --help     Show this help.

EXIT CODES:
  0  done
  2  the guest refused, or could not be reached
  64 bad usage
"""

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments.contains("-h") || arguments.contains("--help") {
    print(usage)
    exit(arguments.isEmpty ? 64 : 0)
}

@MainActor func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

@MainActor func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("multiemu-adb: \(message)\n".utf8))
    exit(code)
}

guard let portText = option("--port"), let port = Int(portText) else {
    fail("--port is required.", code: 64)
}
let keyURL = option("--key").map { URL(fileURLWithPath: $0) }
let timeout = Double(option("--timeout") ?? "60") ?? 60

guard let command = arguments.first else { fail("No command given.", code: 64) }
let operands = Array(arguments.dropFirst())
let device = ADBDevice(port: port, keyURL: keyURL, timeout: timeout)

/// Formats a byte count the way a person reads it.
func describe(_ bytes: Int) -> String {
    bytes >= 1_048_576
        ? String(format: "%.2f MiB", Double(bytes) / 1_048_576)
        : String(format: "%.1f KiB", Double(bytes) / 1024)
}

do {
    switch command {
    case "info":
        print(try device.identify())

    case "shell":
        guard !operands.isEmpty else { fail("shell needs a command.", code: 64) }
        // Joined with spaces, then run by the guest's shell. This is a root-
        // adjacent channel into the guest and the text comes from this
        // machine's command line, never from the guest.
        print(try device.shell(operands.joined(separator: " ")), terminator: "")

    case "push":
        guard operands.count == 2 else { fail("push needs <local> <remote>.", code: 64) }
        let start = ContinuousClock.now
        let sent = try device.push(contentsOf: URL(fileURLWithPath: operands[0]), to: operands[1])
        let seconds = start.durationToNow()
        print("pushed \(describe(sent)) to \(operands[1]) in "
              + String(format: "%.2f s (%.1f MiB/s)", seconds,
                       seconds > 0 ? Double(sent) / 1_048_576 / seconds : 0))

    case "pull":
        guard operands.count == 2 else { fail("pull needs <remote> <local>.", code: 64) }
        let data = try device.pull(operands[0])
        try data.write(to: URL(fileURLWithPath: operands[1]))
        print("pulled \(describe(data.count)) from \(operands[0])")

    case "stat":
        guard operands.count == 1 else { fail("stat needs <remote>.", code: 64) }
        let entry = try device.stat(operands[0])
        guard entry.exists else { fail("\(operands[0]) does not exist in the guest.") }
        print(String(format: "mode %o  size %u  mtime %u",
                     entry.mode, entry.size, entry.modifiedEpoch))

    case "install":
        guard operands.count == 1 else { fail("install needs <apk>.", code: 64) }
        let result = try device.install(apk: URL(fileURLWithPath: operands[0]))
        print("""
        installed \(describe(result.packageBytes))
          push    \(String(format: "%.2f s (%.1f MiB/s)", result.pushSeconds, result.pushMebibytesPerSecond))
          install \(String(format: "%.2f s", result.installSeconds))
          total   \(String(format: "%.2f s", result.totalSeconds))
        """)

    case "uninstall":
        guard operands.count == 1 else { fail("uninstall needs <package>.", code: 64) }
        print(try device.uninstall(operands[0]))

    case "launch":
        guard operands.count == 1 else { fail("launch needs <package>.", code: 64) }
        _ = try device.launch(operands[0])
        print("started \(operands[0])")

    default:
        fail("Unknown command `\(command)`.", code: 64)
    }
} catch {
    fail(String(describing: error))
}

private extension ContinuousClock.Instant {
    func durationToNow() -> Double {
        let duration = self.duration(to: ContinuousClock.now)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }
}
