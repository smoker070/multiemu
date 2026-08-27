import Foundation

/// Renders the compatibility matrix from what a run actually found.
///
/// The document is generated, never edited: a hand-edited row is a claim
/// nobody checked, which is the situation this milestone removes.
public enum MatrixDocument {

    public static func render(_ report: MatrixRunner.Report) -> String {
        var lines: [String] = []

        lines.append("# Compatibility matrix")
        lines.append("")
        lines.append("**Generated — do not edit.** Every row below is the result of running the")
        lines.append("evidence named in `Sources/MultiemuCompatibility/ClaimRegistry.swift`.")
        lines.append("Regenerate with:")
        lines.append("")
        lines.append("```bash")
        lines.append("scripts/compatibility.sh")
        lines.append("```")
        lines.append("")

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        lines.append("| | |")
        lines.append("| --- | --- |")
        lines.append("| Generated | \(stamp.string(from: report.startedAt)) |")
        lines.append("| Host | \(report.hostDescription) |")
        lines.append("| Duration | \(String(format: "%.0f s", report.duration)) |")
        lines.append("| Test suites reported | \(report.suitesRun) |")
        lines.append("| Spikes run | \(report.spikesRun.isEmpty ? "none" : Array(Set(report.spikesRun)).sorted().joined(separator: ", ")) |")
        lines.append("")

        lines.append("## What the words mean")
        lines.append("")
        lines.append("| Status | Meaning |")
        lines.append("| --- | --- |")
        lines.append("| **PASS** | The named evidence ran, in this run, and passed. |")
        lines.append("| inherited | The logic does not vary by architecture, so the Apple Silicon result stands. **Not** a claim that anything ran on Intel. |")
        lines.append("| **FAIL** | The named evidence ran and failed — or does not exist, which is drift. |")
        lines.append("| NOT TESTED | Nothing ran. Not a claim of working. |")
        lines.append("| BLOCKED | Waiting on another milestone, with the reason given. |")
        lines.append("| UNAVAILABLE | Cannot be checked in this environment, with the reason given. |")
        lines.append("")
        lines.append("\"Host-independent\" means the logic does not vary by architecture, so the")
        lines.append("Apple Silicon result carries over. It does **not** mean it was run on Intel.")
        lines.append("")

        // --- Summary ---
        lines.append("## Summary")
        lines.append("")
        lines.append("| Result | Claims |")
        lines.append("| --- | --- |")
        for status in [ClaimStatus.supported, .failed, .notTested, .blocked, .unavailable] {
            let count = report.count(status)
            guard count > 0 else { continue }
            lines.append("| \(status.symbol) | \(count) |")
        }
        lines.append("| **Total** | **\(report.outcomes.count)** |")
        lines.append("")

        if report.failures.isEmpty {
            lines.append("No claim that could be checked failed.")
        } else {
            lines.append("**\(report.failures.count) claim(s) failed:**")
            lines.append("")
            for failure in report.failures {
                lines.append("- `\(failure.claim.id)` — \(failure.claim.capability): \(failure.primaryDetail)")
            }
        }
        lines.append("")

        // --- Sections ---
        for section in MatrixSection.allCases {
            let rows = report.outcomes.filter { $0.claim.section == section }
            guard !rows.isEmpty else { continue }

            lines.append("## \(section.rawValue)")
            lines.append("")
            lines.append("| Capability | Apple Silicon | Intel | Milestone | Evidence |")
            lines.append("| --- | --- | --- | --- | --- |")
            for row in rows {
                let primary = cell(row.primary, detail: row.primaryDetail)
                let intel = cell(row.intel, detail: row.intelDetail)
                lines.append("| \(row.claim.capability) | \(primary) | \(intel) | \(row.claim.milestone) | \(escape(row.primaryDetail)) |")
            }
            lines.append("")
            for row in rows where row.claim.note != nil {
                lines.append("- *\(row.claim.capability)* — \(row.claim.note!)")
            }
            if rows.contains(where: { $0.claim.note != nil }) { lines.append("") }
        }

        // --- Coverage caveats ---
        lines.append("## What this run could not cover")
        lines.append("")
        let unreachable = report.outcomes.filter {
            $0.primary == .blocked || $0.primary == .unavailable || $0.primary == .notTested
        }
        if unreachable.isEmpty {
            lines.append("Nothing — every claim was executed.")
        } else {
            lines.append("| Capability | Why |")
            lines.append("| --- | --- |")
            for row in unreachable {
                lines.append("| \(row.claim.capability) | \(escape(row.primaryDetail)) |")
            }
        }
        lines.append("")
        lines.append("Intel results are absent throughout: no Intel Mac is available to this")
        lines.append("project, so no row claims one.")
        lines.append("")

        // --- What this project actually has to test with ---
        lines.append("## What this project has to test with")
        lines.append("")
        lines.append("A matrix is only as honest as its coverage, so the gaps are listed rather")
        lines.append("than left to be inferred from missing rows.")
        lines.append("")
        lines.append("| Resource | Available | Consequence |")
        lines.append("| --- | --- | --- |")
        lines.append("| \(report.hostDescription) | **yes** — the development machine | Every Apple Silicon result above is a real measurement |")
        lines.append("| An Intel Mac | no | No Intel row claims a result. Host-independent logic is marked as such and inherits the Apple Silicon verdict; nothing else does. |")
        lines.append("| An Android system image | no — `ci.android.com` is unreachable from this environment | Every Android claim is blocked. The boot, input, audio and file-sharing paths are verified against a Linux fixture instead, which carries no evdev, no sound and no 9p driver. |")
        lines.append("| A physical game controller | no — and `GCVirtualController` does not exist on macOS, so one cannot be synthesised | Gamepad translation is unit-tested; no claim is made about real hardware. |")
        lines.append("| A Developer ID identity | no | Notarization and the shipped DMG remain unverified. |")
        lines.append("")
        lines.append("These gaps are project risk, recorded here rather than papered over.")
        lines.append("")

        return lines.joined(separator: "\n")
    }

    private static func cell(_ status: ClaimStatus, detail: String) -> String {
        // A result inherited from the other architecture must not be shown as
        // though it were measured there. The distinction is the difference
        // between "this was checked on Intel" and "this cannot vary by
        // architecture", and only the second is true.
        if detail.hasPrefix("host-independent") {
            return status == .supported ? "inherited" : "inherited (\(status.symbol))"
        }
        switch status {
        case .supported: return "**PASS**"
        case .failed: return "**FAIL**"
        case .notTested: return "NOT TESTED"
        case .blocked: return "BLOCKED"
        case .unavailable: return "UNAVAILABLE"
        }
    }

    /// Table cells are pipe-delimited, so a pipe inside a detail string would
    /// silently add a column.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }
}
