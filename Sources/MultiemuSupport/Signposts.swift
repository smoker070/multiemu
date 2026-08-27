import Foundation
import os

/// Named signposts used by the performance methodology in
/// `docs/PERFORMANCE-METHODOLOGY.md`.
///
/// Signpost names must be `StaticString` for `OSSignposter`, so the canonical
/// spelling lives here as constants and the raw values are duplicated in the
/// documentation table. Anything measured against a published product target
/// gets a signpost; anything else gets a plain log line.
public enum SignpostName {
    public static let hostCapabilityProbe: StaticString = "host.capability.probe"
    public static let backendLaunch: StaticString = "backend.launch"
    public static let guestColdBoot: StaticString = "guest.cold.boot"
    public static let guestFirstBoot: StaticString = "guest.first.boot"
    public static let guestFirstFrame: StaticString = "guest.first.frame"
    public static let frameSubmit: StaticString = "graphics.frame.submit"
    public static let snapshotSave: StaticString = "snapshot.save"
    public static let snapshotRestore: StaticString = "snapshot.restore"
    public static let apkInstall: StaticString = "packages.apk.install"
}

/// Thin wrapper over `OSSignposter` that keeps Instruments-visible intervals
/// from leaking `os` imports into every call site.
///
/// Usage:
/// ```swift
/// let trace = PerformanceTrace(category: .host)
/// let caps = trace.measure(SignpostName.hostCapabilityProbe) { probe.collect() }
/// ```
public struct PerformanceTrace: Sendable {
    private let signposter: OSSignposter

    public init(category: LogCategory) {
        self.signposter = OSSignposter(
            subsystem: MultiemuSubsystem.identifier,
            category: category.rawValue
        )
    }

    public var isEnabled: Bool { signposter.isEnabled }

    public func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    public func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    public func emitEvent(_ name: StaticString) {
        signposter.emitEvent(name)
    }

    /// Measures `body`, emitting an Instruments interval and returning the
    /// wall-clock duration alongside the result.
    public func measure<T>(
        _ name: StaticString,
        _ body: () throws -> T
    ) rethrows -> (value: T, duration: Duration) {
        let state = begin(name)
        let clock = ContinuousClock()
        let start = clock.now
        defer { end(name, state) }
        let value = try body()
        return (value, clock.now - start)
    }
}
