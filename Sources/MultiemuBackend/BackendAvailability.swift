import Foundation
import MultiemuHost

/// Whether a backend could actually be started on this host right now.
///
/// Distinct from `BackendSelection`, which answers "which backend *should* be
/// used for this guest". Availability answers "is the machinery present".
public struct BackendAvailability: Sendable, Equatable {
    public var kind: BackendKind
    public var isAvailable: Bool
    /// Reasons the backend cannot be started. Empty when `isAvailable`.
    public var blockers: [String]
    /// Non-blocking observations worth surfacing in diagnostics.
    public var notes: [String]

    public init(kind: BackendKind, isAvailable: Bool, blockers: [String], notes: [String]) {
        self.kind = kind
        self.isAvailable = isAvailable
        self.blockers = blockers
        self.notes = notes
    }
}

public protocol BackendAvailabilityProbing: Sendable {
    var kind: BackendKind { get }
    func probe(host: HostCapabilities) -> BackendAvailability
}

/// QEMU availability.
///
/// Milestone 1 looks for a developer-installed QEMU on `PATH`. From the packaging
/// milestone onward the shipping application resolves a bundled, signed QEMU
/// inside `Multiemu.app/Contents/Helpers/` instead, and a `PATH` copy is reported
/// only as a diagnostic note — a mismatched Homebrew QEMU shadowing the bundled
/// one is a real support case worth naming explicitly.
public struct QEMUAvailabilityProbe: BackendAvailabilityProbing {
    public let kind: BackendKind
    private let requiresHardwareAcceleration: Bool

    public init(kind: BackendKind = .qemuHardwareAccelerated) {
        self.kind = kind
        self.requiresHardwareAcceleration = (kind == .qemuHardwareAccelerated)
    }

    public func probe(host: HostCapabilities) -> BackendAvailability {
        var blockers: [String] = []
        var notes: [String] = []

        let systemBinaries = host.externalTools.filter { $0.name.hasPrefix("qemu-system-") }
        let present = systemBinaries.filter(\.isPresent)

        if present.isEmpty {
            blockers.append("No qemu-system-* executable was found. Install one for development with `brew install qemu`, or build the bundled helper with scripts/build-qemu.sh.")
        } else {
            for tool in present {
                notes.append("\(tool.name) at \(tool.resolvedPath ?? "?")\(tool.version.map { " [\($0)]" } ?? "")")
            }
            notes.append("This QEMU was found on PATH and is a development convenience. Shipping builds must use the bundled, Developer ID signed helper.")
        }

        if requiresHardwareAcceleration {
            if host.virtualization.hypervisorSupported != true {
                blockers.append("kern.hv_support does not report hardware virtualization support, so -accel hvf cannot be used.")
            }
            if host.virtualization.runningInsideVirtualMachine == true {
                blockers.append("macOS is running inside a virtual machine (kern.hv_vmm_present = 1); nested hardware acceleration is generally unavailable.")
            }
            if !host.codeSigning.hasHypervisorEntitlement {
                notes.append("The current binary does not carry com.apple.security.hypervisor. The QEMU helper — not this process — is what needs that entitlement, so this is expected for the probe CLI.")
            }
        }

        return BackendAvailability(
            kind: kind,
            isAvailable: blockers.isEmpty,
            blockers: blockers,
            notes: notes
        )
    }
}

/// Virtualization.framework availability.
public struct AppleVirtualizationAvailabilityProbe: BackendAvailabilityProbing {
    public let kind: BackendKind = .appleVirtualization

    public init() {}

    public func probe(host: HostCapabilities) -> BackendAvailability {
        var blockers: [String] = []
        var notes: [String] = []

        if !host.virtualization.virtualizationFrameworkSupported {
            blockers.append("VZVirtualMachine.isSupported returned false on this Mac.")
        }
        if !host.codeSigning.hasVirtualizationEntitlement {
            blockers.append("The com.apple.security.virtualization entitlement is missing from this binary's code signature. Virtualization.framework refuses to create a VM without it.")
        }

        notes.append("Retained as a comparison prototype only. See docs/BACKEND-EVALUATION.md for the device-model limitations that make it unsuitable as the primary Android backend.")

        return BackendAvailability(
            kind: kind,
            isAvailable: blockers.isEmpty,
            blockers: blockers,
            notes: notes
        )
    }
}

/// The not-yet-written native VMM.
///
/// Reports honestly rather than silently omitting itself, so the roadmap is
/// visible in diagnostics output.
public struct NativeHypervisorAvailabilityProbe: BackendAvailabilityProbing {
    public let kind: BackendKind = .nativeHypervisor

    public init() {}

    public func probe(host: HostCapabilities) -> BackendAvailability {
        BackendAvailability(
            kind: kind,
            isAvailable: false,
            blockers: ["Not implemented. Writing a virtual machine monitor requires an interrupt controller, timers, a virtio transport and a full device model; it is not scheduled."],
            notes: host.virtualization.hypervisorSupported == true
                ? ["The host does expose the Hypervisor APIs, so this path stays technically open."]
                : []
        )
    }
}

public enum BackendRegistry {
    public static let probes: [any BackendAvailabilityProbing] = [
        QEMUAvailabilityProbe(kind: .qemuHardwareAccelerated),
        QEMUAvailabilityProbe(kind: .qemuSoftwareTranslated),
        AppleVirtualizationAvailabilityProbe(),
        NativeHypervisorAvailabilityProbe(),
    ]

    public static func availability(host: HostCapabilities) -> [BackendAvailability] {
        probes.map { $0.probe(host: host) }
    }
}
