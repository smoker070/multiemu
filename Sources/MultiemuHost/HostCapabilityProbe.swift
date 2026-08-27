import Foundation
import MultiemuSupport

/// Collects a complete `HostCapabilities` snapshot.
///
/// This is the only entry point the rest of the application uses. Everything it
/// calls is synchronous and side-effect free — no files are created, no guest is
/// touched — so it is safe to call at launch, in tests, and inside a diagnostics
/// bundle writer.
public struct HostCapabilityProbe: Sendable {

    public struct Options: Sendable {
        /// Running `--version` on external tools costs a few process spawns.
        /// Disabled in unit tests to keep them hermetic and fast.
        public var runExternalToolVersionCommands: Bool
        public var dataRoot: URL?

        public init(runExternalToolVersionCommands: Bool = true, dataRoot: URL? = nil) {
            self.runExternalToolVersionCommands = runExternalToolVersionCommands
            self.dataRoot = dataRoot
        }

        public static let `default` = Options()
    }

    private let options: Options

    public init(options: Options = .default) {
        self.options = options
    }

    public func collect() -> HostCapabilities {
        let trace = PerformanceTrace(category: .host)
        let (capabilities, duration) = trace.measure(SignpostName.hostCapabilityProbe) {
            HostCapabilities(
                collectedAt: Date(),
                operatingSystem: OperatingSystemProbe.collect(),
                cpu: CPUProbe.collect(),
                memory: MemoryProbe.collect(),
                storage: StorageProbe.collect(dataRoot: options.dataRoot ?? StorageProbe.defaultDataRoot()),
                graphics: GraphicsProbe.collect(),
                virtualization: VirtualizationProbe.collect(),
                codeSigning: CodeSigningProbe.collect(),
                externalTools: ExternalToolProbe.collect(
                    runVersionCommands: options.runExternalToolVersionCommands
                ),
                unverifiedClaims: HostCapabilityProbe.openVerificationItems
            )
        }

        MultiemuLog.host.info(
            """
            Host capability probe finished in \(duration.milliseconds, privacy: .public) ms — \
            arch=\(capabilities.cpu.architecture.rawValue, privacy: .public) \
            hv_support=\(String(describing: capabilities.virtualization.hypervisorSupported), privacy: .public) \
            vz_supported=\(capabilities.virtualization.virtualizationFrameworkSupported, privacy: .public)
            """
        )

        return capabilities
    }

    /// Blocking issues that make the host unusable, as opposed to warnings.
    public static func blockingProblems(for capabilities: HostCapabilities) -> [MultiemuError] {
        var problems: [MultiemuError] = []

        if !capabilities.operatingSystem.meetsMinimumRequirement {
            problems.append(.unsupportedHost(
                reason: "macOS \(capabilities.operatingSystem.productVersion) is installed; macOS 14.0 or later is required."
            ))
        }

        if capabilities.cpu.architecture == .unknown {
            problems.append(.unsupportedHost(reason: "The host CPU architecture could not be identified."))
        }

        if capabilities.virtualization.hypervisorSupported == false {
            problems.append(.hostRequirementNotMet(
                requirement: "Hardware virtualization",
                detail: "kern.hv_support reports 0. Every Android guest would have to be fully software-emulated, which does not meet product quality standards."
            ))
        }

        if !capabilities.graphics.metalAvailable {
            problems.append(.hostRequirementNotMet(
                requirement: "Metal",
                detail: "No Metal device was found. The display pipeline requires Metal."
            ))
        }

        return problems
    }

    /// Version-sensitive assertions this code makes that have not been confirmed
    /// against primary documentation on the running OS. Mirrored in docs/VERIFY.md.
    public static let openVerificationItems: [UnverifiedClaim] = [
        UnverifiedClaim(
            id: "VZ-SAVE-RESTORE",
            claim: "Virtualization.framework can save and restore Linux VM state on macOS 14+, which would back the snapshot feature if the VZ backend were chosen.",
            verification: "Build a minimal VZLinuxBootLoader configuration and call VZVirtualMachineConfiguration.validateSaveRestoreSupport(); confirm against Apple's Virtualization documentation for the running macOS version."
        ),
        UnverifiedClaim(
            id: "VZ-VIRTIO-GPU-3D",
            claim: "VZVirtioGraphicsDeviceConfiguration exposes 2D virtio-gpu only, with no Venus/gfxstream 3D path, so Android SurfaceFlinger would fall back to software rendering under the VZ backend.",
            verification: "Boot a Linux guest under VZ, run `lspci -k` and check whether the virtio-gpu driver reports VIRGL/DRM 3D capability; cross-check Apple's VZVirtioGraphicsDeviceConfiguration documentation."
        ),
        UnverifiedClaim(
            id: "HVF-ENTITLEMENT-SET",
            claim: "A helper process using Hypervisor.framework on Apple Silicon needs com.apple.security.hypervisor and nothing further.",
            verification: "Run `codesign -d --entitlements - <path-to-known-working-hypervisor-binary>` and compare; confirm against Apple's Hypervisor framework documentation."
        ),
        UnverifiedClaim(
            id: "QEMU-HVF-AARCH64-MATURITY",
            claim: "qemu-system-aarch64 with -accel hvf and -machine virt boots a modern Linux kernel reliably on Apple Silicon under macOS 14+.",
            verification: "Milestone 2 executes exactly this and records the result. Until then this is an assumption."
        ),
        UnverifiedClaim(
            id: "NESTED-VIRT-API",
            claim: "VZGenericPlatformConfiguration.isNestedVirtualizationSupported exists on macOS 15+ and reports M3-and-later capability.",
            verification: "Compile-time availability is proven by this file building. Runtime meaning must be confirmed against Apple's documentation for the running macOS version."
        ),
    ]
}
