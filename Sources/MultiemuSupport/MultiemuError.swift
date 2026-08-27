import Foundation

/// The single error type crossing Multiemu module boundaries.
///
/// Every case carries enough context to be shown to a user *and* to be acted
/// upon, because the product constraint is "actionable error reporting from the
/// earliest milestones". `remediation` is the sentence we put in the UI; the
/// enum payload is what we put in the diagnostics bundle.
public enum MultiemuError: Error, Sendable, Equatable {

    /// The Mac cannot host Multiemu at all (OS too old, unknown architecture).
    case unsupportedHost(reason: String)

    /// A specific host prerequisite is missing but the host is otherwise valid.
    case hostRequirementNotMet(requirement: String, detail: String)

    /// A backend exists in the code base but is unusable on this host right now.
    case backendUnavailable(backend: String, reason: String)

    /// A backend is planned but not implemented yet. Used deliberately so that
    /// "not built" never masquerades as "not supported".
    case backendNotImplemented(backend: String, milestone: String)

    /// A required external executable is missing.
    case toolMissing(tool: String, purpose: String, installHint: String)

    /// Guest RAM request cannot be honoured safely against host memory.
    case insufficientMemory(requestedBytes: UInt64, hostPhysicalBytes: UInt64, hostAvailableBytes: UInt64)

    /// Virtual disk request cannot be honoured against free space.
    case insufficientStorage(requestedBytes: UInt64, availableBytes: UInt64, path: String)

    /// A configuration value is out of range or internally inconsistent.
    case invalidConfiguration(field: String, detail: String)

    /// The request fits this Mac on its own, but not alongside what is already
    /// running. Distinct from `insufficientMemory` because the remedy is
    /// different: stop a device rather than reconfigure this one.
    case hostBudgetExhausted(
        resource: String,
        requestedBytes: UInt64,
        committedBytes: UInt64,
        budgetBytes: UInt64,
        runningDeviceCount: Int
    )

    public var remediation: String {
        switch self {
        case let .unsupportedHost(reason):
            return "This Mac cannot run Multiemu: \(reason)"
        case let .hostRequirementNotMet(requirement, detail):
            return "\(requirement) is required. \(detail)"
        case let .backendUnavailable(backend, reason):
            return "The \(backend) backend is unavailable: \(reason)"
        case let .backendNotImplemented(backend, milestone):
            return "The \(backend) backend is not implemented yet (planned for \(milestone))."
        case let .toolMissing(tool, purpose, installHint):
            return "\(tool) is required for \(purpose). \(installHint)"
        case let .insufficientMemory(requested, physical, available):
            return """
            Requested \(ByteCount.describe(requested)) of guest RAM, but this Mac has \
            \(ByteCount.describe(physical)) installed and about \(ByteCount.describe(available)) \
            available. Reduce the device's memory or close other applications.
            """
        case let .insufficientStorage(requested, available, path):
            return """
            Requested \(ByteCount.describe(requested)) of virtual storage but only \
            \(ByteCount.describe(available)) is free at \(path).
            """
        case let .invalidConfiguration(field, detail):
            return "\(field) is invalid: \(detail)"
        case let .hostBudgetExhausted(resource, requested, committed, budget, running):
            let devices = running == 1 ? "1 running device" : "\(running) running devices"
            return """
            \(ByteCount.describe(requested)) of \(resource) requested, but \
            \(ByteCount.describe(committed)) is already committed to \(devices) and this Mac \
            allows \(ByteCount.describe(budget)) in total. Stop a running device, or give this \
            one less \(resource).
            """
        }
    }
}

extension MultiemuError: LocalizedError {
    public var errorDescription: String? { remediation }
}

extension MultiemuError: CustomStringConvertible {
    public var description: String { remediation }
}

/// Byte formatting shared by errors, logs and the probe report.
///
/// Deliberately base-2 with explicit `GiB`/`MiB` units: virtual-device memory
/// and disk sizes are always powers of two, and showing a 4 GiB guest as
/// "4.29 GB" in a UI that also says "4096 MB" reads as a bug.
public enum ByteCount {
    public static let kiB: UInt64 = 1024
    public static let miB: UInt64 = 1024 * 1024
    public static let giB: UInt64 = 1024 * 1024 * 1024

    public static func describe(_ bytes: UInt64) -> String {
        if bytes >= giB {
            return String(format: "%.2f GiB", Double(bytes) / Double(giB))
        }
        if bytes >= miB {
            return String(format: "%.1f MiB", Double(bytes) / Double(miB))
        }
        if bytes >= kiB {
            return String(format: "%.1f KiB", Double(bytes) / Double(kiB))
        }
        return "\(bytes) B"
    }
}
