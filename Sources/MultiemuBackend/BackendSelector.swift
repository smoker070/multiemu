import Foundation
import MultiemuHost

/// The minimal set of host facts backend selection depends on.
///
/// Selection is deliberately a pure function of this small struct rather than of
/// `HostCapabilities`. That keeps the compatibility matrix executable: every row
/// of docs/COMPATIBILITY-MATRIX.md is a unit test that constructs this input
/// directly, with no dependency on the machine running the tests.
public struct BackendSelectionInput: Sendable, Equatable {
    public var hostArchitecture: HostArchitecture
    public var hardwareVirtualizationAvailable: Bool
    public var macOSMajorVersion: Int
    public var metalAvailable: Bool
    public var runningInsideVirtualMachine: Bool

    public init(
        hostArchitecture: HostArchitecture,
        hardwareVirtualizationAvailable: Bool,
        macOSMajorVersion: Int,
        metalAvailable: Bool,
        runningInsideVirtualMachine: Bool = false
    ) {
        self.hostArchitecture = hostArchitecture
        self.hardwareVirtualizationAvailable = hardwareVirtualizationAvailable
        self.macOSMajorVersion = macOSMajorVersion
        self.metalAvailable = metalAvailable
        self.runningInsideVirtualMachine = runningInsideVirtualMachine
    }

    public init(host: HostCapabilities) {
        self.init(
            hostArchitecture: host.cpu.architecture,
            hardwareVirtualizationAvailable: host.hardwareVirtualizationAvailable,
            macOSMajorVersion: host.operatingSystem.majorVersion,
            metalAvailable: host.graphics.metalAvailable,
            runningInsideVirtualMachine: host.virtualization.runningInsideVirtualMachine ?? false
        )
    }
}

public struct BackendSelection: Sendable, Equatable {
    public var guestArchitecture: GuestArchitecture
    public var recommendedBackend: BackendKind?
    public var acceleration: AccelerationMode?
    public var supportLevel: SupportLevel
    public var implementationStatus: ImplementationStatus
    public var rationale: String
    public var warnings: [String]
    public var alternatives: [BackendKind]

    public init(
        guestArchitecture: GuestArchitecture,
        recommendedBackend: BackendKind?,
        acceleration: AccelerationMode?,
        supportLevel: SupportLevel,
        implementationStatus: ImplementationStatus,
        rationale: String,
        warnings: [String],
        alternatives: [BackendKind]
    ) {
        self.guestArchitecture = guestArchitecture
        self.recommendedBackend = recommendedBackend
        self.acceleration = acceleration
        self.supportLevel = supportLevel
        self.implementationStatus = implementationStatus
        self.rationale = rationale
        self.warnings = warnings
        self.alternatives = alternatives
    }

    /// True when the combination should be offered to a user as a normal choice.
    /// `degraded` combinations are reachable only through an explicit,
    /// clearly-labelled advanced option.
    public var isOfferedByDefault: Bool { supportLevel >= .experimental }
}

/// Chooses a backend for a (host, guest) pair.
///
/// This is the single place in the code base that encodes architecture policy.
/// The rest of the application asks this type and never inspects the host CPU
/// itself.
public enum BackendSelector {

    public static func select(
        guestArchitecture guest: GuestArchitecture,
        input: BackendSelectionInput
    ) -> BackendSelection {

        var warnings: [String] = []

        // Hard host gates first.
        if input.macOSMajorVersion < 14 {
            return BackendSelection(
                guestArchitecture: guest,
                recommendedBackend: nil,
                acceleration: nil,
                supportLevel: .unsupported,
                implementationStatus: .notStarted,
                rationale: "macOS 14.0 or later is required; this host reports macOS \(input.macOSMajorVersion).",
                warnings: [],
                alternatives: []
            )
        }

        if input.hostArchitecture == .unknown {
            return BackendSelection(
                guestArchitecture: guest,
                recommendedBackend: nil,
                acceleration: nil,
                supportLevel: .unsupported,
                implementationStatus: .notStarted,
                rationale: "The host CPU architecture could not be identified, so no backend can be chosen safely.",
                warnings: [],
                alternatives: []
            )
        }

        if !input.metalAvailable {
            warnings.append("No Metal device was detected. The display pipeline requires Metal; expect the guest to boot headless at best.")
        }

        if input.runningInsideVirtualMachine {
            warnings.append("macOS is itself running inside a virtual machine. Nested hardware acceleration is generally unavailable.")
        }

        let architectureMatches = guest.matches(input.hostArchitecture)

        // Same architecture: hardware virtualization is the only acceptable path.
        if architectureMatches {
            guard input.hardwareVirtualizationAvailable else {
                warnings.append("kern.hv_support reports that hardware virtualization is unavailable, so a same-architecture guest would still have to be translated.")
                return BackendSelection(
                    guestArchitecture: guest,
                    recommendedBackend: .qemuSoftwareTranslated,
                    acceleration: .softwareTranslation,
                    supportLevel: .degraded,
                    implementationStatus: BackendCatalogue.descriptor(for: .qemuSoftwareTranslated).implementationStatus,
                    rationale: "Guest and host architectures match, but this Mac does not expose the Hypervisor APIs, so only software translation remains.",
                    warnings: warnings,
                    alternatives: []
                )
            }

            let descriptor = BackendCatalogue.descriptor(for: .qemuHardwareAccelerated)
            return BackendSelection(
                guestArchitecture: guest,
                recommendedBackend: .qemuHardwareAccelerated,
                acceleration: .hardwareVirtualization,
                supportLevel: .experimental,
                implementationStatus: descriptor.implementationStatus,
                rationale: """
                    The \(guest.displayName) guest matches this \(input.hostArchitecture.displayName) host, so guest \
                    instructions execute natively under Hypervisor.framework. QEMU is preferred over \
                    Virtualization.framework because an Android guest needs devices Virtualization.framework does not \
                    expose (3D-capable virtio-gpu, a controllable device model, and qcow2-backed snapshots).
                    """,
                warnings: warnings,
                alternatives: [.appleVirtualization]
            )
        }

        // Cross architecture: possible, but never product quality.
        warnings.append("""
            Cross-architecture execution: a \(guest.displayName) guest on an \(input.hostArchitecture.displayName) host must \
            translate every guest instruction. Expect a large slowdown versus native. This combination is not a \
            product-quality target and must not be offered as a default.
            """)

        return BackendSelection(
            guestArchitecture: guest,
            recommendedBackend: .qemuSoftwareTranslated,
            acceleration: .softwareTranslation,
            supportLevel: .degraded,
            implementationStatus: BackendCatalogue.descriptor(for: .qemuSoftwareTranslated).implementationStatus,
            rationale: "Guest architecture \(guest.rawValue) does not match host architecture \(input.hostArchitecture.rawValue); hardware virtualization cannot be used and dynamic binary translation is the only option.",
            warnings: warnings,
            alternatives: []
        )
    }

    /// The full matrix for a host: one selection per guest architecture.
    public static func compatibilityMatrix(input: BackendSelectionInput) -> [BackendSelection] {
        GuestArchitecture.allCases.map { select(guestArchitecture: $0, input: input) }
    }

    /// The guest architecture that should be offered first on this host.
    public static func preferredGuestArchitecture(input: BackendSelectionInput) -> GuestArchitecture? {
        compatibilityMatrix(input: input)
            .filter(\.isOfferedByDefault)
            .max { $0.supportLevel < $1.supportLevel }?
            .guestArchitecture
    }
}
