import Foundation
import MultiemuSupport

/// Renders `HostCapabilities` as human-readable text or stable JSON.
///
/// The JSON form is the interchange format for diagnostics bundles and for
/// regression tests that must compare hosts, so its encoding settings are fixed
/// here rather than at each call site.
public enum HostReportFormatter {

    public static func json(_ capabilities: HostCapabilities) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(capabilities)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(json: String) throws -> HostCapabilities {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HostCapabilities.self, from: Data(json.utf8))
    }

    public static func text(_ capabilities: HostCapabilities) -> String {
        var lines: [String] = []

        func section(_ title: String) {
            lines.append("")
            lines.append(title)
            lines.append(String(repeating: "-", count: title.count))
        }

        func row(_ label: String, _ value: String) {
            lines.append("  \(label.padding(toLength: 34, withPad: " ", startingAt: 0)) \(value)")
        }

        func optionalRow(_ label: String, _ value: String?) {
            row(label, value ?? "unknown")
        }

        lines.append("Multiemu host capability report")
        lines.append("schema \(capabilities.schemaVersion)  collected \(ISO8601DateFormatter().string(from: capabilities.collectedAt))")

        section("Operating system")
        row("Version", "macOS \(capabilities.operatingSystem.productVersion) (\(capabilities.operatingSystem.buildVersion))")
        row("Meets macOS 14+ requirement", capabilities.operatingSystem.meetsMinimumRequirement ? "yes" : "NO")

        section("CPU")
        row("Architecture", capabilities.cpu.architecture.displayName)
        row("Brand", capabilities.cpu.brand)
        row("Machine model", capabilities.cpu.machineModel)
        row("Cores (logical/physical)", "\(capabilities.cpu.logicalCores)/\(capabilities.cpu.physicalCores)")
        optionalRow("Performance cores", capabilities.cpu.performanceCores.map(String.init))
        optionalRow("Efficiency cores", capabilities.cpu.efficiencyCores.map(String.init))
        row("Recommended guest vCPUs", "\(capabilities.cpu.recommendedGuestVCPUCount)")

        section("Memory")
        row("Physical", ByteCount.describe(capabilities.memory.physicalBytes))
        row("Estimated available", ByteCount.describe(capabilities.memory.estimatedAvailableBytes))
        row("Wired", ByteCount.describe(capabilities.memory.wiredBytes))
        row("Compressed", ByteCount.describe(capabilities.memory.compressedBytes))
        optionalRow("Swap used / total", capabilities.memory.swapUsedBytes.map { used in
            "\(ByteCount.describe(used)) / \(ByteCount.describe(capabilities.memory.swapTotalBytes ?? 0))"
        })
        row("Page size", ByteCount.describe(capabilities.memory.pageSizeBytes))

        section("Storage")
        row("Data root", capabilities.storage.dataRootPath)
        row("Filesystem", capabilities.storage.filesystemType)
        optionalRow("Available", capabilities.storage.availableBytes.map(ByteCount.describe))
        optionalRow("Available (important usage)", capabilities.storage.availableForImportantUsageBytes.map(ByteCount.describe))
        row("Sparse virtual disks possible", capabilities.storage.supportsSparseFiles ? "yes" : "NO — disks would be fully allocated")

        section("Graphics")
        row("Metal available", capabilities.graphics.metalAvailable ? "yes" : "NO")
        if let gpu = capabilities.graphics.defaultDevice {
            row("Default GPU", gpu.name)
            row("Unified memory", gpu.hasUnifiedMemory ? "yes" : "no")
            row("Recommended working set", ByteCount.describe(gpu.recommendedMaxWorkingSetBytes))
            row("Metal family", "apple7+=\(gpu.supportsAppleFamily7OrLater) mac2=\(gpu.supportsMac2)")
        }
        if capabilities.graphics.allDevices.count > 1 {
            row("Additional GPUs", capabilities.graphics.allDevices.map(\.name).joined(separator: ", "))
        }

        section("Virtualization")
        optionalRow("kern.hv_support", capabilities.virtualization.hypervisorSupported.map { $0 ? "1 (supported)" : "0 (NOT supported)" })
        optionalRow("Running inside a VM", capabilities.virtualization.runningInsideVirtualMachine.map { $0 ? "yes" : "no" })
        row("Virtualization.framework", capabilities.virtualization.virtualizationFrameworkSupported ? "supported" : "not supported")
        row("Hypervisor.framework present", capabilities.virtualization.hypervisorFrameworkPresent ? "yes" : "no")
        optionalRow("Nested virtualization", capabilities.virtualization.nestedVirtualizationSupported.map { $0 ? "supported" : "not supported" })
        optionalRow("Rosetta Linux translation", capabilities.virtualization.rosettaLinuxTranslation)

        section("Code signature of this binary")
        row("Signed", capabilities.codeSigning.isSigned ? "yes" : "no")
        optionalRow("Identifier", capabilities.codeSigning.signingIdentifier)
        optionalRow("Team", capabilities.codeSigning.teamIdentifier)
        row("Hardened runtime", capabilities.codeSigning.hardenedRuntimeEnabled ? "enabled" : "disabled")
        row("com.apple.security.hypervisor", capabilities.codeSigning.hasHypervisorEntitlement ? "present" : "absent")
        row("com.apple.security.virtualization", capabilities.codeSigning.hasVirtualizationEntitlement ? "present" : "absent")
        if !capabilities.codeSigning.entitlementKeys.isEmpty {
            row("All entitlements", capabilities.codeSigning.entitlementKeys.joined(separator: ", "))
        }

        section("External tools")
        for tool in capabilities.externalTools {
            let status = tool.resolvedPath.map { path in
                tool.version.map { "\(path)  [\($0)]" } ?? path
            } ?? "MISSING — needed from \(tool.requiredFromMilestone)"
            row(tool.name, status)
        }

        section("Unverified claims (see docs/VERIFY.md)")
        for claim in capabilities.unverifiedClaims {
            lines.append("  [\(claim.id)] \(claim.claim)")
            lines.append("      verify: \(claim.verification)")
        }

        return lines.joined(separator: "\n")
    }
}
