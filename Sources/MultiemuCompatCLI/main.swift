import Foundation
import MultiemuCompatibility
import MultiemuHost
import MultiemuSupport

// multiemu-compat — Milestone 20.
//
// Runs every claim the compatibility matrix makes and writes the matrix from
// what happened. The document is an output, not an input.

setvbuf(stdout, nil, _IONBF, 0)

let help = """
multiemu-compat — run the compatibility matrix

USAGE:
  multiemu-compat --list
  multiemu-compat --run [--kernel <path>] [--initrd <path>] [--no-spikes]
                        [--output docs/COMPATIBILITY-MATRIX.md] [--json <path>]

OPTIONS:
  --list          Print the claims and what backs each, without running anything.
  --run           Execute the claims.
  --kernel/-initrd  Guest images the spikes need. Without them, spike-backed
                  claims report as untested rather than passing.
  --no-spikes     Suites only. Faster; spike-backed claims read as untested.
  --output        Where to write the generated matrix.
  --json          Also write the raw results.

Exit status is non-zero if any claim that COULD be checked failed. Untested is
not failure — a matrix that failed whenever something was out of reach would be
ignored, which is worse than one that says plainly what it did not cover.
"""

var argv = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let index = argv.firstIndex(of: name), index + 1 < argv.count else { return nil }
    return argv[index + 1]
}

let packageDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

guard !argv.isEmpty, !argv.contains("-h"), !argv.contains("--help") else {
    print(help)
    exit(argv.isEmpty ? 64 : 0)
}

// --- Listing ---

if argv.contains("--list") {
    print("Compatibility claims (\(ClaimRegistry.all.count))\n")
    for section in MatrixSection.allCases {
        let claims = ClaimRegistry.all.filter { $0.section == section }
        guard !claims.isEmpty else { continue }
        print("\(section.rawValue)")
        for claim in claims {
            let backing: String
            switch claim.primary {
            case let .suite(name): backing = "suite \"\(name)\""
            case let .spike(product, _): backing = product
            case let .script(path, _): backing = path
            case let .suiteAndSpike(name, product, _): backing = "suite \"\(name)\" + \(product)"
            case .sameAsPrimary: backing = "mirrors the primary result"
            case let .unavailable(reason): backing = "unavailable — \(reason)"
            case let .blocked(by, reason): backing = "blocked by \(by) — \(reason)"
            }
            print("  \(claim.id.padding(toLength: 26, withPad: " ", startingAt: 0)) \(backing)")
        }
        print("")
    }
    let executable = ClaimRegistry.all.filter(\.primary.isExecutable).count
    print("\(executable) of \(ClaimRegistry.all.count) claims can be executed here.")
    exit(0)
}

guard argv.contains("--run") else {
    print(help)
    exit(64)
}

// --- Running ---

let host = HostCapabilityProbe(options: .init(runExternalToolVersionCommands: false)).collect()
let hostDescription = """
\(host.cpu.brand) · \(host.cpu.architecture.displayName) · \
macOS \(host.operatingSystem.productVersion) · \
\(ByteCount.describe(host.memory.physicalBytes))
"""

let configuration = MatrixRunner.Configuration(
    packageDirectory: packageDirectory,
    binaryDirectory: packageDirectory.appendingPathComponent(".build/release"),
    kernelURL: option("--kernel").map { URL(fileURLWithPath: $0) },
    initrdURL: option("--initrd").map { URL(fileURLWithPath: $0) },
    runsSpikes: !argv.contains("--no-spikes"))

print("multiemu-compat")
print("  host: \(hostDescription)")
print("  claims: \(ClaimRegistry.all.count)")
if configuration.kernelURL == nil, configuration.runsSpikes {
    print("  no --kernel given, so guest spikes cannot run; those claims will read as untested")
}
print("")

let runner = MatrixRunner(configuration: configuration) { message in print(message) }
let report = await runner.run(hostDescription: hostDescription)

print("")
print("Result")
for status in [ClaimStatus.supported, .failed, .notTested, .blocked, .unavailable] {
    let count = report.count(status)
    guard count > 0 else { continue }
    print("  \(status.symbol.padding(toLength: 14, withPad: " ", startingAt: 0)) \(count)")
}
if !report.failures.isEmpty {
    print("")
    print("Failed:")
    for failure in report.failures {
        print("  \(failure.claim.id) — \(failure.primaryDetail)")
    }
}
if !report.testIssues.isEmpty {
    print("")
    print("Issues the test run reported:")
    for issue in report.testIssues.prefix(20) { print("  \(issue)") }
}

// --- Output ---

let outputPath = option("--output") ?? "docs/COMPATIBILITY-MATRIX.md"
let outputURL = URL(fileURLWithPath: outputPath, relativeTo: packageDirectory)
do {
    try MatrixDocument.render(report).write(to: outputURL, atomically: true, encoding: .utf8)
    print("")
    print("Matrix written to \(outputPath)")
} catch {
    FileHandle.standardError.write(Data("could not write \(outputPath): \(error)\n".utf8))
}

if let jsonPath = option("--json") {
    let payload: [String: Any] = [
        "generatedAt": ISO8601DateFormatter().string(from: report.startedAt),
        "host": report.hostDescription,
        "durationSeconds": report.duration,
        "suitesReported": report.suitesRun,
        "suitesFailed": report.suitesFailed,
        "spikesRun": report.spikesRun,
        "spikesFailed": report.spikesFailed,
        "claims": report.outcomes.map { outcome in
            [
                "id": outcome.claim.id,
                "section": outcome.claim.section.rawValue,
                "capability": outcome.claim.capability,
                "milestone": outcome.claim.milestone,
                "appleSilicon": outcome.primary.rawValue,
                "appleSiliconDetail": outcome.primaryDetail,
                "intel": outcome.intel.rawValue,
                "intelDetail": outcome.intelDetail,
            ]
        },
    ]
    if let data = try? JSONSerialization.data(
        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: jsonPath, relativeTo: packageDirectory))
        print("Results written to \(jsonPath)")
    }
}

// Untested is not failure: a matrix that failed whenever something was out of
// reach would stop being run, and then it would record nothing at all.
exit(report.failures.isEmpty ? 0 : 1)
