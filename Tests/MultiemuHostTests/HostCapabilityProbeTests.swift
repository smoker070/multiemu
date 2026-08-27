import Foundation
import Testing
@testable import MultiemuHost

@Suite("HostCapabilityProbe")
struct HostCapabilityProbeTests {

    /// Tool version commands are skipped so the suite does not spawn processes.
    private static let probe = HostCapabilityProbe(
        options: .init(runExternalToolVersionCommands: false)
    )

    @Test("Probe returns internally consistent values on the running host")
    func probeInvariants() {
        let capabilities = Self.probe.collect()

        #expect(capabilities.schemaVersion == HostCapabilities.currentSchemaVersion)
        #expect(capabilities.cpu.architecture != .unknown)
        #expect(capabilities.cpu.logicalCores >= capabilities.cpu.physicalCores)
        #expect(capabilities.cpu.recommendedGuestVCPUCount >= 2)
        #expect(capabilities.cpu.recommendedGuestVCPUCount <= capabilities.cpu.logicalCores)
        #expect(capabilities.memory.physicalBytes > 0)
        #expect(capabilities.memory.estimatedAvailableBytes <= capabilities.memory.physicalBytes)
        #expect(capabilities.memory.pageSizeBytes > 0)
        #expect(!capabilities.storage.dataRootPath.isEmpty)
        #expect(!capabilities.externalTools.isEmpty)
        #expect(!capabilities.unverifiedClaims.isEmpty)
    }

    @Test("Probe does not create the data root as a side effect")
    func probeIsSideEffectFree() throws {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("multiemu-probe-test-\(UUID().uuidString)", isDirectory: true)

        let capabilities = HostCapabilityProbe(
            options: .init(runExternalToolVersionCommands: false, dataRoot: temporary)
        ).collect()

        #expect(capabilities.storage.dataRootPath == temporary.path)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        // The volume was still measured, via the nearest existing ancestor.
        #expect(capabilities.storage.filesystemType != "unknown")
    }

    @Test("Host architecture matches the compiled architecture")
    func architectureMatchesBuild() {
        let capabilities = Self.probe.collect()
        #if arch(arm64)
        #expect(capabilities.cpu.architecture == .appleSilicon)
        #elseif arch(x86_64)
        // A Rosetta-translated x86_64 build running on Apple Silicon would
        // legitimately report .appleSilicon here, so both are accepted.
        #expect(capabilities.cpu.architecture == .intel || capabilities.cpu.architecture == .appleSilicon)
        #endif
    }

    @Test("Apple Silicon hosts expose performance-core counts")
    func performanceCoresOnAppleSilicon() {
        let capabilities = Self.probe.collect()
        if capabilities.cpu.architecture == .appleSilicon {
            #expect(capabilities.cpu.performanceCores != nil)
            #expect(capabilities.cpu.efficiencyCores != nil)
        }
    }

    @Test("Report round-trips through JSON without loss")
    func jsonRoundTrip() throws {
        let original = Self.probe.collect()
        let json = try HostReportFormatter.json(original)
        let decoded = try HostReportFormatter.decode(json: json)
        // Date is encoded at second resolution by ISO8601, so compare everything else.
        #expect(decoded.cpu == original.cpu)
        #expect(decoded.memory == original.memory)
        #expect(decoded.storage == original.storage)
        #expect(decoded.graphics == original.graphics)
        #expect(decoded.virtualization == original.virtualization)
        #expect(decoded.codeSigning == original.codeSigning)
        #expect(decoded.externalTools == original.externalTools)
    }

    @Test("Text report contains every section heading")
    func textReportSections() {
        let text = HostReportFormatter.text(Self.probe.collect())
        for heading in ["Operating system", "CPU", "Memory", "Storage", "Graphics", "Virtualization", "External tools"] {
            #expect(text.contains(heading), "missing section: \(heading)")
        }
    }

    @Test("A macOS 13 host is reported as a blocking problem")
    func macOS13IsBlocked() {
        let old = HostCapabilities.makeFixture(macOSMajor: 13)
        let problems = HostCapabilityProbe.blockingProblems(for: old)
        #expect(problems.contains { if case .unsupportedHost = $0 { return true } else { return false } })
    }

    @Test("A host without hardware virtualization is reported as a blocking problem")
    func noHypervisorIsBlocked() {
        let host = HostCapabilities.makeFixture(hypervisorSupported: false)
        let problems = HostCapabilityProbe.blockingProblems(for: host)
        #expect(problems.contains { if case .hostRequirementNotMet = $0 { return true } else { return false } })
    }

    @Test("A healthy fixture host reports no blocking problems")
    func healthyHostHasNoProblems() {
        #expect(HostCapabilityProbe.blockingProblems(for: .makeFixture()).isEmpty)
    }
}
