import Foundation
import Testing
@testable import MultiemuBackend
import MultiemuHost

/// Executable form of docs/COMPATIBILITY-MATRIX.md.
///
/// Every row of the published matrix has a test here. When the matrix changes,
/// this file must change with it — that coupling is intentional, because a
/// documented compatibility claim that nothing enforces is how emulators end up
/// promising x86 Android on Apple Silicon.
@Suite("Backend selection matrix")
struct BackendSelectorTests {

    private func appleSilicon(
        hardwareVirtualization: Bool = true,
        macOSMajor: Int = 14,
        metal: Bool = true,
        insideVM: Bool = false
    ) -> BackendSelectionInput {
        BackendSelectionInput(
            hostArchitecture: .appleSilicon,
            hardwareVirtualizationAvailable: hardwareVirtualization,
            macOSMajorVersion: macOSMajor,
            metalAvailable: metal,
            runningInsideVirtualMachine: insideVM
        )
    }

    private func intel(
        hardwareVirtualization: Bool = true,
        macOSMajor: Int = 14,
        metal: Bool = true
    ) -> BackendSelectionInput {
        BackendSelectionInput(
            hostArchitecture: .intel,
            hardwareVirtualizationAvailable: hardwareVirtualization,
            macOSMajorVersion: macOSMajor,
            metalAvailable: metal
        )
    }

    // MARK: - Matrix rows

    @Test("Apple Silicon host + ARM64 guest → hardware accelerated QEMU")
    func appleSiliconArm64() {
        let selection = BackendSelector.select(guestArchitecture: .arm64, input: appleSilicon())
        #expect(selection.recommendedBackend == .qemuHardwareAccelerated)
        #expect(selection.acceleration == .hardwareVirtualization)
        #expect(selection.supportLevel == .experimental)
        #expect(selection.warnings.isEmpty)
        #expect(selection.alternatives.contains(.appleVirtualization))
    }

    @Test("Apple Silicon host + x86_64 guest → software translation, degraded, warned")
    func appleSiliconX86() {
        let selection = BackendSelector.select(guestArchitecture: .x86_64, input: appleSilicon())
        #expect(selection.recommendedBackend == .qemuSoftwareTranslated)
        #expect(selection.acceleration == .softwareTranslation)
        #expect(selection.supportLevel == .degraded)
        #expect(!selection.isOfferedByDefault)
        #expect(selection.warnings.contains { $0.contains("Cross-architecture") })
    }

    @Test("Intel host + x86_64 guest → hardware accelerated QEMU")
    func intelX86() {
        let selection = BackendSelector.select(guestArchitecture: .x86_64, input: intel())
        #expect(selection.recommendedBackend == .qemuHardwareAccelerated)
        #expect(selection.acceleration == .hardwareVirtualization)
        #expect(selection.supportLevel == .experimental)
        #expect(selection.warnings.isEmpty)
    }

    @Test("Intel host + ARM64 guest → software translation, degraded, warned")
    func intelArm64() {
        let selection = BackendSelector.select(guestArchitecture: .arm64, input: intel())
        #expect(selection.recommendedBackend == .qemuSoftwareTranslated)
        #expect(selection.supportLevel == .degraded)
        #expect(!selection.isOfferedByDefault)
    }

    @Test("Matching architecture without hv_support falls back to translation and says why")
    func matchingArchitectureWithoutHypervisor() {
        let selection = BackendSelector.select(
            guestArchitecture: .arm64,
            input: appleSilicon(hardwareVirtualization: false)
        )
        #expect(selection.recommendedBackend == .qemuSoftwareTranslated)
        #expect(selection.supportLevel == .degraded)
        #expect(selection.warnings.contains { $0.contains("kern.hv_support") })
    }

    @Test("macOS 13 is unsupported regardless of guest architecture")
    func macOS13Unsupported() {
        for guest in GuestArchitecture.allCases {
            let selection = BackendSelector.select(
                guestArchitecture: guest,
                input: appleSilicon(macOSMajor: 13)
            )
            #expect(selection.supportLevel == .unsupported)
            #expect(selection.recommendedBackend == nil)
        }
    }

    @Test("Unknown host architecture yields no backend")
    func unknownHostArchitecture() {
        let input = BackendSelectionInput(
            hostArchitecture: .unknown,
            hardwareVirtualizationAvailable: true,
            macOSMajorVersion: 15,
            metalAvailable: true
        )
        let selection = BackendSelector.select(guestArchitecture: .arm64, input: input)
        #expect(selection.recommendedBackend == nil)
        #expect(selection.supportLevel == .unsupported)
    }

    @Test("Missing Metal is a warning, not a backend change")
    func missingMetalWarns() {
        let selection = BackendSelector.select(guestArchitecture: .arm64, input: appleSilicon(metal: false))
        #expect(selection.recommendedBackend == .qemuHardwareAccelerated)
        #expect(selection.warnings.contains { $0.contains("Metal") })
    }

    @Test("Running inside a VM warns about nested acceleration")
    func nestedVirtualizationWarns() {
        let selection = BackendSelector.select(guestArchitecture: .arm64, input: appleSilicon(insideVM: true))
        #expect(selection.warnings.contains { $0.contains("virtual machine") })
    }

    // MARK: - Derived helpers

    @Test("Preferred guest architecture follows the host architecture")
    func preferredGuestArchitecture() {
        #expect(BackendSelector.preferredGuestArchitecture(input: appleSilicon()) == .arm64)
        #expect(BackendSelector.preferredGuestArchitecture(input: intel()) == .x86_64)
        #expect(BackendSelector.preferredGuestArchitecture(input: appleSilicon(macOSMajor: 13)) == nil)
    }

    @Test("Every host produces one selection per guest architecture")
    func matrixIsComplete() {
        let matrix = BackendSelector.compatibilityMatrix(input: appleSilicon())
        #expect(matrix.count == GuestArchitecture.allCases.count)
        #expect(Set(matrix.map(\.guestArchitecture)) == Set(GuestArchitecture.allCases))
    }

    @Test("Support levels order from unsupported to supported")
    func supportLevelOrdering() {
        #expect(SupportLevel.unsupported < SupportLevel.degraded)
        #expect(SupportLevel.degraded < SupportLevel.experimental)
        #expect(SupportLevel.experimental < SupportLevel.supported)
    }
}

@Suite("Backend catalogue")
struct BackendCatalogueTests {

    @Test("Catalogue covers every BackendKind exactly once")
    func catalogueIsComplete() {
        let kinds = BackendCatalogue.all.map(\.kind)
        #expect(Set(kinds) == Set(BackendKind.allCases))
        #expect(kinds.count == BackendKind.allCases.count)
    }

    @Test("Only hardware backends advertise hardware acceleration")
    func accelerationClaimsAreConsistent() {
        for descriptor in BackendCatalogue.all {
            let claimsHardware = descriptor.capabilities.contains(.hardwareAcceleration)
            #expect(claimsHardware == (descriptor.acceleration == .hardwareVirtualization))
        }
    }

    @Test("No backend claims to be implemented until a guest has booted under it")
    func nothingIsImplementedYet() {
        // Milestone 2 built and tested QEMU command construction, process
        // supervision and the QMP message layer, and proved guest execution via
        // Hypervisor.framework directly — but no Android guest has booted under
        // any backend. `.implemented` is reserved for Milestone 4 and later.
        // This test is the tripwire that forces the catalogue to stay honest.
        for descriptor in BackendCatalogue.all {
            #expect(descriptor.implementationStatus != .implemented,
                    "\(descriptor.kind) claims .implemented before a guest has booted")
        }
    }

    @Test("Every backend that has code behind it is marked at least prototype")
    func prototypesAreDeclared() {
        for kind in [BackendKind.qemuHardwareAccelerated, .qemuSoftwareTranslated, .appleVirtualization] {
            #expect(BackendCatalogue.descriptor(for: kind).implementationStatus == .prototype)
        }
    }

    @Test("Every descriptor carries a licensing note")
    func licensingNotesPresent() {
        for descriptor in BackendCatalogue.all {
            #expect(!descriptor.licensingNote.isEmpty)
        }
    }
}

@Suite("Backend availability")
struct BackendAvailabilityTests {

    @Test("QEMU is unavailable when no qemu-system binary is present")
    func qemuMissing() {
        let host = HostCapabilities.makeFixture(externalTools: [])
        let availability = QEMUAvailabilityProbe().probe(host: host)
        #expect(!availability.isAvailable)
        #expect(availability.blockers.contains { $0.contains("qemu-system") })
    }

    @Test("QEMU accelerated is unavailable without hv_support even when installed")
    func qemuWithoutHypervisor() {
        let host = HostCapabilities.makeFixture(
            hypervisorSupported: false,
            externalTools: [
                ExternalTool(
                    name: "qemu-system-aarch64",
                    purpose: "test",
                    requiredFromMilestone: "M2",
                    resolvedPath: "/opt/homebrew/bin/qemu-system-aarch64",
                    version: "QEMU emulator version 10.0.0",
                    installHint: ""
                )
            ]
        )
        let availability = QEMUAvailabilityProbe(kind: .qemuHardwareAccelerated).probe(host: host)
        #expect(!availability.isAvailable)
        #expect(availability.blockers.contains { $0.contains("hv_support") })
    }

    @Test("QEMU software translation ignores hv_support")
    func qemuTCGIgnoresHypervisor() {
        let host = HostCapabilities.makeFixture(
            hypervisorSupported: false,
            externalTools: [
                ExternalTool(
                    name: "qemu-system-aarch64",
                    purpose: "test",
                    requiredFromMilestone: "M2",
                    resolvedPath: "/opt/homebrew/bin/qemu-system-aarch64",
                    version: nil,
                    installHint: ""
                )
            ]
        )
        let availability = QEMUAvailabilityProbe(kind: .qemuSoftwareTranslated).probe(host: host)
        #expect(availability.isAvailable)
    }

    @Test("Virtualization.framework requires the entitlement")
    func virtualizationNeedsEntitlement() {
        let withoutEntitlement = AppleVirtualizationAvailabilityProbe()
            .probe(host: .makeFixture(entitlementKeys: []))
        #expect(!withoutEntitlement.isAvailable)
        #expect(withoutEntitlement.blockers.contains { $0.contains("com.apple.security.virtualization") })

        let withEntitlement = AppleVirtualizationAvailabilityProbe()
            .probe(host: .makeFixture(entitlementKeys: ["com.apple.security.virtualization"]))
        #expect(withEntitlement.isAvailable)
    }

    @Test("The native VMM reports itself as not implemented, never as unsupported hardware")
    func nativeHypervisorIsHonest() {
        let availability = NativeHypervisorAvailabilityProbe().probe(host: .makeFixture())
        #expect(!availability.isAvailable)
        #expect(availability.blockers.contains { $0.contains("Not implemented") })
    }

    @Test("Registry probes every backend kind")
    func registryCoversAllKinds() {
        let kinds = Set(BackendRegistry.availability(host: .makeFixture()).map(\.kind))
        #expect(kinds == Set(BackendKind.allCases))
    }
}
