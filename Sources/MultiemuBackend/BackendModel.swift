import Foundation
import MultiemuHost

/// The CPU architecture of the Android **guest**.
///
/// Kept separate from `HostArchitecture` on purpose. The single most important
/// compatibility fact in this project is whether host and guest architectures
/// match, and that comparison must be explicit at the one place that decides
/// backends rather than implicit in `#if arch(...)` checks spread through the app.
public enum GuestArchitecture: String, Codable, Sendable, CaseIterable {
    case arm64
    case x86_64

    public var displayName: String {
        switch self {
        case .arm64: return "ARM64 (arm64-v8a)"
        case .x86_64: return "x86_64"
        }
    }

    /// The Android ABI string a guest of this architecture reports as
    /// `ro.product.cpu.abi`.
    public var androidPrimaryABI: String {
        switch self {
        case .arm64: return "arm64-v8a"
        case .x86_64: return "x86_64"
        }
    }

    public func matches(_ host: HostArchitecture) -> Bool {
        switch (self, host) {
        case (.arm64, .appleSilicon), (.x86_64, .intel): return true
        default: return false
        }
    }
}

/// Every backend Multiemu may ever run a guest on.
///
/// A backend is identified by *engine plus acceleration*, not just engine,
/// because "QEMU" alone tells you nothing about whether a guest will be usable:
/// QEMU with HVF and QEMU with TCG differ by one to two orders of magnitude in
/// CPU throughput and must never be silently substituted for one another.
public enum BackendKind: String, Codable, Sendable, CaseIterable {
    /// QEMU system emulator using Apple's Hypervisor.framework accelerator
    /// (`-accel hvf`). Same-architecture guests only.
    case qemuHardwareAccelerated

    /// QEMU system emulator using its own dynamic binary translator
    /// (`-accel tcg`). Cross-architecture guests. Order-of-magnitude slower.
    case qemuSoftwareTranslated

    /// Apple's Virtualization.framework (`VZVirtualMachine`).
    case appleVirtualization

    /// A Multiemu-owned virtual machine monitor written directly against
    /// Hypervisor.framework. Not started; see docs/BACKEND-EVALUATION.md.
    case nativeHypervisor

    public var displayName: String {
        switch self {
        case .qemuHardwareAccelerated: return "QEMU (hardware accelerated, HVF)"
        case .qemuSoftwareTranslated: return "QEMU (software translation, TCG)"
        case .appleVirtualization: return "Apple Virtualization.framework"
        case .nativeHypervisor: return "Multiemu native VMM (Hypervisor.framework)"
        }
    }
}

public enum AccelerationMode: String, Codable, Sendable {
    case hardwareVirtualization
    case softwareTranslation

    public var displayName: String {
        switch self {
        case .hardwareVirtualization: return "hardware virtualization"
        case .softwareTranslation: return "software translation"
        }
    }
}

/// How well a combination is expected to work, as a product statement.
///
/// `degraded` exists specifically so cross-architecture combinations can be
/// offered without being advertised as usable, which the product constraints
/// require.
public enum SupportLevel: String, Codable, Sendable, CaseIterable, Comparable {
    /// Unsupported: will not be offered.
    case unsupported
    /// Runs, but does not meet product quality standards. Never a default.
    case degraded
    /// Expected to work; not yet validated by the milestone that proves it.
    case experimental
    /// Validated against this milestone's acceptance criteria.
    case supported

    private var rank: Int {
        switch self {
        case .unsupported: return 0
        case .degraded: return 1
        case .experimental: return 2
        case .supported: return 3
        }
    }

    public static func < (lhs: SupportLevel, rhs: SupportLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Whether the code for a backend exists yet.
///
/// Deliberately distinct from `SupportLevel`: "we have not written it" and
/// "this Mac cannot do it" are different answers to the user and must never be
/// collapsed into one error message.
public enum ImplementationStatus: String, Codable, Sendable {
    case notStarted
    case prototype
    case implemented
}

/// Features a backend can provide. Used to keep UI affordances honest: the
/// snapshot button is only shown when the active backend reports `.snapshots`.
public enum BackendCapability: String, Codable, Sendable, CaseIterable {
    case hardwareAcceleration
    case virtioGPU2D
    case virtioGPU3D
    case snapshots
    case liveSuspendResume
    case vsock
    case userModeNetworking
    case bridgedNetworking
    case audioOutput
    case audioInput
    case hostDirectorySharing
    case clipboardSharing
    case usbPassthrough
    case customDeviceModel
}

public struct BackendDescriptor: Codable, Sendable, Equatable {
    public var kind: BackendKind
    public var supportedHostArchitectures: [HostArchitecture]
    public var supportedGuestArchitectures: [GuestArchitecture]
    public var acceleration: AccelerationMode
    public var implementationStatus: ImplementationStatus
    public var plannedMilestone: String
    public var capabilities: Set<BackendCapability>
    /// One-line redistribution consequence. The authoritative version is
    /// docs/DEPENDENCIES-AND-LICENSING.md.
    public var licensingNote: String

    public init(
        kind: BackendKind,
        supportedHostArchitectures: [HostArchitecture],
        supportedGuestArchitectures: [GuestArchitecture],
        acceleration: AccelerationMode,
        implementationStatus: ImplementationStatus,
        plannedMilestone: String,
        capabilities: Set<BackendCapability>,
        licensingNote: String
    ) {
        self.kind = kind
        self.supportedHostArchitectures = supportedHostArchitectures
        self.supportedGuestArchitectures = supportedGuestArchitectures
        self.acceleration = acceleration
        self.implementationStatus = implementationStatus
        self.plannedMilestone = plannedMilestone
        self.capabilities = capabilities
        self.licensingNote = licensingNote
    }
}

/// The declared backend catalogue.
///
/// Capability sets below describe what each engine *can* provide, not what
/// Multiemu has wired up. `implementationStatus` carries that second fact.
public enum BackendCatalogue {

    public static let all: [BackendDescriptor] = [
        BackendDescriptor(
            kind: .qemuHardwareAccelerated,
            supportedHostArchitectures: [.appleSilicon, .intel],
            supportedGuestArchitectures: [.arm64, .x86_64],
            acceleration: .hardwareVirtualization,
            // M2: command construction, process supervision and the QMP message
            // layer exist and are tested. No guest has been booted under it.
            implementationStatus: .prototype,
            plannedMilestone: "M2 (command line + supervision); M4 boots a guest",
            capabilities: [
                .hardwareAcceleration, .virtioGPU2D, .virtioGPU3D, .snapshots,
                .liveSuspendResume, .vsock, .userModeNetworking, .bridgedNetworking,
                .audioOutput, .audioInput, .hostDirectorySharing, .usbPassthrough,
                .customDeviceModel,
            ],
            licensingNote: "GPL-2.0-only. Ships as a separate signed executable, never linked into the application. Corresponding source must be published."
        ),
        BackendDescriptor(
            kind: .qemuSoftwareTranslated,
            supportedHostArchitectures: [.appleSilicon, .intel],
            supportedGuestArchitectures: [.arm64, .x86_64],
            acceleration: .softwareTranslation,
            implementationStatus: .prototype,
            plannedMilestone: "M2 (command line + supervision); never a default",
            capabilities: [
                .virtioGPU2D, .virtioGPU3D, .snapshots, .liveSuspendResume, .vsock,
                .userModeNetworking, .bridgedNetworking, .audioOutput, .audioInput,
                .hostDirectorySharing, .customDeviceModel,
            ],
            licensingNote: "GPL-2.0-only. Same distribution treatment as the accelerated variant."
        ),
        BackendDescriptor(
            kind: .appleVirtualization,
            supportedHostArchitectures: [.appleSilicon, .intel],
            supportedGuestArchitectures: [.arm64, .x86_64],
            acceleration: .hardwareVirtualization,
            // M2: configuration builder exists and passes Apple's own
            // validate() and validateSaveRestoreSupport(). Comparison only.
            implementationStatus: .prototype,
            plannedMilestone: "M2 (comparison prototype only; not a shipping backend)",
            capabilities: [
                .hardwareAcceleration, .virtioGPU2D, .liveSuspendResume, .vsock,
                .userModeNetworking, .bridgedNetworking, .audioOutput, .audioInput,
                .hostDirectorySharing, .clipboardSharing,
            ],
            licensingNote: "Apple system framework. No redistribution obligation. Requires the com.apple.security.virtualization entitlement; bridged networking additionally requires the managed com.apple.vm.networking entitlement."
        ),
        BackendDescriptor(
            kind: .nativeHypervisor,
            supportedHostArchitectures: [.appleSilicon, .intel],
            supportedGuestArchitectures: [.arm64, .x86_64],
            acceleration: .hardwareVirtualization,
            // M2: multiemu-hvprobe created a VM, mapped guest memory, created a
            // vCPU and executed guest instructions on Apple Silicon. The path is
            // proven to be real; building a full device model is still unscheduled.
            implementationStatus: .prototype,
            plannedMilestone: "not scheduled (execution proven in M2 by multiemu-hvprobe)",
            capabilities: [.hardwareAcceleration, .customDeviceModel],
            licensingNote: "Fully owned code. Requires the com.apple.security.hypervisor entitlement. Removes the GPL obligation entirely, at the cost of writing an interrupt controller, timer, virtio transport and full device model."
        ),
    ]

    public static func descriptor(for kind: BackendKind) -> BackendDescriptor {
        // Force-unwrap is safe: `all` covers every case of BackendKind and the
        // BackendCatalogueTests test asserts that invariant.
        all.first { $0.kind == kind }!
    }
}
