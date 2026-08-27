import Darwin
import Foundation
import MultiemuBackend
import MultiemuHost
import MultiemuSupport

// multiemu-probe — Milestone 1 deliverable.
//
// Reports what this Mac can host, which backend would be selected for each guest
// architecture, and whether the default virtual-device profile fits. Exits
// non-zero when a blocking host problem is found so it can gate CI.
//
// No third-party argument parser: the dependency policy in Package.swift keeps
// the core free of source dependencies, and the option surface here is small.

struct Arguments {
    enum Format: String {
        case text
        case json
    }

    var format: Format = .text
    var outputPath: String?
    var runToolVersionCommands = true
    var dataRoot: String?
    var showHelp = false

    static func parse(_ argv: [String]) throws -> Arguments {
        var result = Arguments()
        var index = 0
        while index < argv.count {
            let argument = argv[index]
            switch argument {
            case "--format", "-f":
                index += 1
                guard index < argv.count, let format = Format(rawValue: argv[index]) else {
                    throw MultiemuError.invalidConfiguration(field: "--format", detail: "Expected 'text' or 'json'.")
                }
                result.format = format
            case "--output", "-o":
                index += 1
                guard index < argv.count else {
                    throw MultiemuError.invalidConfiguration(field: "--output", detail: "Expected a file path.")
                }
                result.outputPath = argv[index]
            case "--data-root":
                index += 1
                guard index < argv.count else {
                    throw MultiemuError.invalidConfiguration(field: "--data-root", detail: "Expected a directory path.")
                }
                result.dataRoot = argv[index]
            case "--no-tool-versions":
                result.runToolVersionCommands = false
            case "--help", "-h":
                result.showHelp = true
            default:
                throw MultiemuError.invalidConfiguration(field: "arguments", detail: "Unrecognised option '\(argument)'.")
            }
            index += 1
        }
        return result
    }
}

let helpText = """
multiemu-probe — Multiemu host capability report

USAGE:
  multiemu-probe [--format text|json] [--output <path>] [--data-root <path>]
                 [--no-tool-versions] [--help]

OPTIONS:
  -f, --format <text|json>   Output format. Default: text.
  -o, --output <path>        Write the report to a file instead of stdout.
      --data-root <path>     Probe storage for this directory instead of
                             ~/Library/Application Support/Multiemu.
      --no-tool-versions     Skip running `--version` on external tools.
  -h, --help                 Show this help.

EXIT CODES:
  0  Host is usable.
  2  A blocking host problem was found (see the "Blocking problems" section).
  64 Bad usage.
"""

func renderBackendReport(host: HostCapabilities) -> String {
    var lines: [String] = []
    let input = BackendSelectionInput(host: host)

    lines.append("")
    lines.append("Backend selection")
    lines.append("-----------------")
    for selection in BackendSelector.compatibilityMatrix(input: input) {
        let backend = selection.recommendedBackend?.displayName ?? "none"
        lines.append("  Guest \(selection.guestArchitecture.displayName)")
        lines.append("    backend        \(backend)")
        lines.append("    acceleration   \(selection.acceleration?.displayName ?? "n/a")")
        lines.append("    support level  \(selection.supportLevel.rawValue)")
        lines.append("    implementation \(selection.implementationStatus.rawValue)")
        lines.append("    rationale      \(selection.rationale.replacingOccurrences(of: "\n", with: " "))")
        for warning in selection.warnings {
            lines.append("    warning        \(warning.replacingOccurrences(of: "\n", with: " "))")
        }
        if !selection.alternatives.isEmpty {
            lines.append("    alternatives   \(selection.alternatives.map(\.displayName).joined(separator: ", "))")
        }
    }

    if let preferred = BackendSelector.preferredGuestArchitecture(input: input) {
        lines.append("  Preferred guest architecture for this host: \(preferred.displayName)")
    } else {
        lines.append("  No guest architecture is offered by default on this host.")
    }

    lines.append("")
    lines.append("Backend availability")
    lines.append("--------------------")
    for availability in BackendRegistry.availability(host: host) {
        lines.append("  \(availability.kind.displayName): \(availability.isAvailable ? "available" : "unavailable")")
        for blocker in availability.blockers {
            lines.append("    blocker  \(blocker)")
        }
        for note in availability.notes {
            lines.append("    note     \(note)")
        }
    }

    lines.append("")
    lines.append("Default virtual-device profile preflight (4 GiB RAM, 32 GiB storage)")
    lines.append("--------------------------------------------------------------------")
    let request = GuestResourceRequest.defaultProfile(vcpuCount: host.cpu.recommendedGuestVCPUCount)
    let validation = ResourceValidator.validate(request, host: host)
    lines.append("  vCPUs                \(request.vcpuCount)")
    lines.append("  Memory               \(ByteCount.describe(request.memoryBytes))")
    lines.append("  Storage              \(ByteCount.describe(request.storageBytes)) (\(host.storage.supportsSparseFiles ? "sparse" : "fully allocated"))")
    lines.append("  Max guest RAM here   \(ByteCount.describe(ResourceValidator.maximumAllowedGuestMemory(physicalBytes: host.memory.physicalBytes)))")
    lines.append("  Verdict              \(validation.isAllowed ? "allowed" : "REFUSED")")
    for error in validation.errors {
        lines.append("    error    \(error.remediation.replacingOccurrences(of: "\n", with: " "))")
    }
    for warning in validation.warnings {
        lines.append("    warning  \(warning.replacingOccurrences(of: "\n", with: " "))")
    }

    return lines.joined(separator: "\n")
}

// MARK: - Entry point

do {
    let arguments = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))

    if arguments.showHelp {
        print(helpText)
        exit(0)
    }

    let probe = HostCapabilityProbe(options: .init(
        runExternalToolVersionCommands: arguments.runToolVersionCommands,
        dataRoot: arguments.dataRoot.map { URL(fileURLWithPath: $0) }
    ))
    let capabilities = probe.collect()
    let blockingProblems = HostCapabilityProbe.blockingProblems(for: capabilities)

    let report: String
    switch arguments.format {
    case .json:
        report = try HostReportFormatter.json(capabilities)
    case .text:
        var text = HostReportFormatter.text(capabilities)
        text += "\n" + renderBackendReport(host: capabilities)
        text += "\n\nBlocking problems\n-----------------\n"
        if blockingProblems.isEmpty {
            text += "  none\n"
        } else {
            for problem in blockingProblems {
                text += "  - \(problem.remediation)\n"
            }
        }
        report = text
    }

    if let path = arguments.outputPath {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Atomic writes go through a temporary file and a rename, which cannot
        // work for character devices, named pipes or /dev/null. Prefer atomic
        // for real report files, then fall back so that redirecting the report
        // to a device still behaves the way a command-line tool should.
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            try report.write(to: url, atomically: false, encoding: .utf8)
        }
        FileHandle.standardError.write(Data("Wrote \(path)\n".utf8))
    } else {
        print(report)
    }

    exit(blockingProblems.isEmpty ? 0 : 2)
} catch let error as MultiemuError {
    FileHandle.standardError.write(Data("multiemu-probe: \(error.remediation)\n\n\(helpText)\n".utf8))
    exit(64)
} catch {
    FileHandle.standardError.write(Data("multiemu-probe: \(error)\n".utf8))
    exit(1)
}
