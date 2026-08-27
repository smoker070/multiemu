import Foundation

/// How a claim in the compatibility matrix is backed.
///
/// Every row in the matrix asserts something about what this emulator can do.
/// Until this milestone those rows were written by hand and updated by hand,
/// which means they record what someone believed at the time. Each one now has
/// to name the thing that demonstrates it — or say plainly that nothing does.
public enum Evidence: Sendable, Equatable {
    /// A test suite that must pass. The name is the `@Suite` title.
    case suite(String)
    /// A spike binary that must exit zero.
    case spike(product: String, arguments: [String] = [])
    /// A script in the repository that must exit zero. Not all evidence is a
    /// Swift target — the packaging checks are shell, and excluding them would
    /// mean the matrix silently covered less than it appears to.
    case script(path: String, arguments: [String] = [])
    /// Both: the logic is unit-tested *and* demonstrated against a live guest.
    case suiteAndSpike(suite: String, product: String, arguments: [String] = [])
    /// The claim is host-independent, so the Apple Silicon result stands.
    case sameAsPrimary
    /// Cannot be executed in this environment, and why.
    case unavailable(reason: String)
    /// Waiting on another milestone, and why.
    case blocked(by: String, reason: String)

    /// Whether running the matrix can decide this one.
    public var isExecutable: Bool {
        switch self {
        case .suite, .spike, .suiteAndSpike, .script: return true
        case .sameAsPrimary, .unavailable, .blocked: return false
        }
    }
}

/// What running the matrix concluded.
public enum ClaimStatus: String, Sendable, Codable {
    case supported
    case failed
    case notTested = "NOT YET TESTED"
    case blocked
    case unavailable

    public var symbol: String {
        switch self {
        case .supported: return "PASS"
        case .failed: return "FAIL"
        case .notTested: return "NOT TESTED"
        case .blocked: return "BLOCKED"
        case .unavailable: return "UNAVAILABLE"
        }
    }
}

public enum MatrixSection: String, Sendable, CaseIterable, Codable {
    case hostAndGuest = "Host and guest architecture"
    case androidVersions = "Android versions"
    case boot = "Boot and lifecycle"
    case graphics = "Graphics and display"
    case input = "Input"
    case storage = "Storage and snapshots"
    case networking = "Networking"
    case sharing = "File exchange and clipboard"
    case multiInstance = "Multiple devices"
    case packaging = "Application and packaging"
    case failures = "Failure and edge cases"
}

/// One row of the compatibility matrix.
public struct CompatibilityClaim: Sendable, Equatable {
    public var id: String
    public var section: MatrixSection
    public var capability: String
    public var primary: Evidence
    public var intel: Evidence
    public var milestone: String
    public var note: String?

    public init(
        id: String,
        section: MatrixSection,
        capability: String,
        primary: Evidence,
        intel: Evidence = .unavailable(reason: "no Intel host is available to this project"),
        milestone: String,
        note: String? = nil
    ) {
        self.id = id
        self.section = section
        self.capability = capability
        self.primary = primary
        self.intel = intel
        self.milestone = milestone
        self.note = note
    }
}

public struct ClaimOutcome: Sendable, Equatable {
    public var claim: CompatibilityClaim
    public var primary: ClaimStatus
    public var intel: ClaimStatus
    public var primaryDetail: String
    public var intelDetail: String

    /// A claim only counts as broken when something that *could* be checked was
    /// checked and failed. Untested is not failure, and saying otherwise would
    /// make the matrix useless the moment anything is out of reach.
    public var isFailure: Bool { primary == .failed || intel == .failed }
}
