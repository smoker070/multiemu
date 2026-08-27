import Foundation

/// A guest service this host cannot satisfy, and why.
public struct UnsupportedGuestService: Sendable, Equatable {
    /// The name Android's init uses, which is also the name in
    /// `init.svc.<name>` and the argument to `ctl.stop`.
    public let initServiceName: String
    /// What it needs that this host cannot provide. Recorded rather than
    /// summarised, because "unsupported" with no reason is how a working
    /// service ends up disabled by a later edit.
    public let reason: String

    public init(initServiceName: String, reason: String) {
        self.initServiceName = initServiceName
        self.reason = reason
    }
}

/// Stops guest services that cannot work on this host and that init is
/// therefore restarting forever.
///
/// **Why this exists.** Android's init restarts a crashing service about every
/// second, indefinitely. On the Cuttlefish images this project runs, two
/// services can never start, so the guest spends its idle life forking them,
/// crashing, logging the crash and forking again. Measured on Android 17 with
/// four vCPUs, the loops cost about a quarter of all idle host CPU — the single
/// largest item, larger than everything the emulator itself does. See
/// `docs/PERFORMANCE-METHODOLOGY.md`.
///
/// **Why stopping is the only option.** Both failures are host capabilities
/// that do not exist here, not misconfiguration:
///
/// - `vendor.ril-daemon` prints `'ro.boot.modem_simulator_ports' must be an
///   integer vsock port for the modem simulator` and, given one, would open
///   `AF_VSOCK`. QEMU 11.1.0 on macOS builds no vsock device at all — `-device
///   help` lists none — so the modem simulator can never be reached.
/// - `vendor.threadnetwork_hal` fails `Check failed: node_id > 0` until
///   `androidboot.openthread_node_id` is set, and then gets one step further
///   and dies in `ot-rcp`: `utilsInitSocket() at simul_utils.c:370: Failure`,
///   because the simulated radio binds to the interface in
///   `persist.vendor.otsim.local_interface`, default `eth1`, which this guest
///   does not have. Setting the node id alone makes idle CPU slightly *worse*,
///   since each restart now does more work before dying.
public enum GuestServiceQuiesce {

    /// What init reports in `init.svc.<name>` for a service it is crash-looping.
    public static let restartingState = "restarting"

    /// The services this host cannot support on a Cuttlefish Android image.
    ///
    /// Deliberately a short, named list rather than a pattern. A rule broad
    /// enough to catch "anything that looks like a radio" would eventually
    /// catch something that works.
    public static let cuttlefishServices: [UnsupportedGuestService] = [
        .init(
            initServiceName: "vendor.ril-daemon",
            reason: "the Cuttlefish modem simulator is reached over vsock, and this QEMU build has no vsock device"),
        .init(
            initServiceName: "vendor.threadnetwork_hal",
            reason: "its simulated radio binds to an `eth1` interface this guest does not have"),
    ]

    public enum Decision: Sendable, Equatable {
        /// init is restarting it, and this host cannot make it succeed.
        case stop(UnsupportedGuestService)
        /// Anything else. Carries the observed state so a report can say why.
        case leave(service: UnsupportedGuestService, state: String?)

        public var serviceName: String {
            switch self {
            case let .stop(service): return service.initServiceName
            case let .leave(service, _): return service.initServiceName
            }
        }
    }

    /// Decides what to stop from what init reports.
    ///
    /// **Only a service init is actively restarting is stopped.** Not one that
    /// is running, not one already stopped, and not one whose state could not
    /// be read. That rule is the whole safety argument: on an image where these
    /// services work — a different board, a future image, a host that grows a
    /// vsock device — the list still names them and nothing is touched. A list
    /// applied blind would disable a working radio the day the image changed.
    public static func decisions(
        for services: [UnsupportedGuestService],
        state: [String: String]
    ) -> [Decision] {
        services.map { service in
            let observed = state[service.initServiceName]
            guard observed == restartingState else { return .leave(service: service, state: observed) }
            return .stop(service)
        }
    }

    /// What a quiesce did, for the caller to report.
    public struct Outcome: Sendable, Equatable {
        public var stopped: [String] = []
        public var left: [(name: String, state: String)] {
            leftPairs.map { (name: $0.0, state: $0.1) }
        }
        var leftPairs: [(String, String)] = []
        /// Services asked to stop that did not reach `stopped`.
        public var refused: [String] = []

        public static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.stopped == rhs.stopped && lhs.refused == rhs.refused
                && lhs.leftPairs.map(\.0) == rhs.leftPairs.map(\.0)
                && lhs.leftPairs.map(\.1) == rhs.leftPairs.map(\.1)
        }

        public var summary: String {
            var parts: [String] = []
            if !stopped.isEmpty { parts.append("stopped \(stopped.joined(separator: ", "))") }
            if !refused.isEmpty { parts.append("could not stop \(refused.joined(separator: ", "))") }
            for entry in leftPairs { parts.append("left \(entry.0) (\(entry.1))") }
            return parts.isEmpty ? "nothing to quiesce" : parts.joined(separator: "; ")
        }
    }

    /// Reads each service's state over the guest console, stops the ones init
    /// is crash-looping, and verifies each stop took.
    ///
    /// Blocking. Run it off the cooperative thread pool.
    public static func perform(
        over session: GuestConsoleShell.Session,
        services: [UnsupportedGuestService] = cuttlefishServices
    ) -> Outcome {
        var state: [String: String] = [:]
        for service in services {
            if let value = session.value(of: "getprop init.svc.\(service.initServiceName)") {
                state[service.initServiceName] = value
            }
        }

        var outcome = Outcome()
        for decision in decisions(for: services, state: state) {
            switch decision {
            case let .leave(service, observed):
                outcome.leftPairs.append((service.initServiceName, observed ?? "state unreadable"))
            case let .stop(service):
                session.run("setprop ctl.stop \(service.initServiceName)")
                // Verified, not assumed: `ctl.stop` is a property write that
                // fails silently when the caller may not set it, and a quiesce
                // that reports success it did not achieve is worse than none.
                let after = session.value(of: "getprop init.svc.\(service.initServiceName)")
                if after == "stopped" {
                    outcome.stopped.append(service.initServiceName)
                } else {
                    outcome.refused.append(service.initServiceName)
                }
            }
        }
        return outcome
    }
}
