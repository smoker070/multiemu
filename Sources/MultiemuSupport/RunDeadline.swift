import Darwin
import Foundation

/// A hard wall-clock ceiling on a whole harness run, enforced off the
/// cooperative pool.
///
/// Every phase of `multiemu-perf` already carries its own deadline, and each
/// one is written correctly — yet a run once held four host cores at full tilt
/// for eleven minutes and produced neither a report nor an error. Per-phase
/// deadlines could not have caught it: they are `Task.sleep`s, and the guest
/// calls in the workload phase block in `recv` on the cooperative pool. Once
/// enough of its threads sit in a blocking read, the executor has nothing left
/// to resume the sleeps with, so the very timers meant to bound the run are the
/// first thing the stall disables.
///
/// Hence a thread rather than a `Task`. A thread the pool does not own cannot
/// be starved by the pool, so this fires whatever the executor is doing. For
/// the same reason it holds the guest's pid rather than the process object:
/// killing then needs no isolation the expiring thread might not be able to
/// reach.
///
/// The ceiling is a backstop for the case where the ordinary deadlines cannot
/// run, not a substitute for them. A run that reaches it has already failed;
/// the ceiling only decides whether it fails in minutes or holds the machine
/// until someone notices the fans.
public final class RunDeadline: @unchecked Sendable {

    /// What the run was doing when it ran out of time.
    public struct Expiry: Sendable {
        /// The ceiling that was exceeded, in seconds.
        public let limit: Double
        /// The phase last entered — the harness's own description of where it
        /// stalled, which is the one thing a wall-clock kill would otherwise
        /// destroy the evidence for.
        public let phase: String
        /// The guest to kill, or 0 if none had been adopted yet.
        public let guestPID: Int32
    }

    private let limit: Double
    private let pollInterval: Double
    private let onExpiry: @Sendable (Expiry) -> Void

    private let lock = NSLock()
    private var phase = "starting up"
    private var guestPID: Int32 = 0
    private var isFinished = false

    /// - Parameters:
    ///   - limit: Seconds from `start()` until expiry.
    ///   - pollInterval: How often the thread checks. Sleeping in short hops
    ///     rather than one long sleep is what lets `finish()` retire the thread
    ///     promptly on the successful path instead of leaving it parked for the
    ///     remainder of the ceiling.
    ///   - onExpiry: Run on the watchdog's own thread when the ceiling passes.
    ///     Injected so the decision to kill the process tree belongs to the
    ///     executable and this stays testable without one.
    public init(
        limit: Double,
        pollInterval: Double = 0.5,
        onExpiry: @escaping @Sendable (Expiry) -> Void
    ) {
        self.limit = limit
        self.pollInterval = pollInterval
        self.onExpiry = onExpiry
    }

    /// The ceiling to use when the caller does not name one.
    ///
    /// Derived from the run's own flags rather than a constant, so raising
    /// `--settle` cannot make a legitimate run trip the backstop. Doubling the
    /// sum, then flooring it, allows for everything between the phases that has
    /// no flag — the display handshake, guest ADB setup, writing the report —
    /// while still bounding the run at something a person will wait through.
    public static func defaultLimit(
        bootCeiling: Double,
        settleSeconds: Double,
        idleSeconds: Double,
        sampleSeconds: Double
    ) -> Double {
        let budget = bootCeiling + settleSeconds + idleSeconds + sampleSeconds
        return max(300, budget * 2)
    }

    /// Records what the run is doing, for the expiry message.
    public func enter(_ phase: String) {
        lock.lock()
        self.phase = phase
        lock.unlock()
    }

    /// Names the guest to kill on expiry. Called once QEMU has a pid.
    public func adopt(guestPID: Int32) {
        lock.lock()
        self.guestPID = guestPID
        lock.unlock()
    }

    /// Stands the watchdog down. The run finished on its own terms.
    public func finish() {
        lock.lock()
        isFinished = true
        lock.unlock()
    }

    /// Kills the adopted guest, if there is one.
    ///
    /// Exposed because every abnormal exit needs it, not only expiry: an early
    /// `exit()` from the harness leaves QEMU orphaned and still spinning its
    /// vCPUs, which is the same held-hostage machine by a different route.
    public func killGuest() {
        lock.lock()
        let pid = guestPID
        lock.unlock()
        guard pid > 0 else { return }
        Darwin.kill(pid, SIGKILL)
    }

    /// Starts counting. Call before anything that could hang.
    public func start() {
        let thread = Thread { [self] in
            let deadline = Date().addingTimeInterval(limit)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: pollInterval)
                lock.lock()
                let finished = isFinished
                lock.unlock()
                if finished { return }
            }
            lock.lock()
            let expiry = Expiry(limit: limit, phase: phase, guestPID: guestPID)
            let finished = isFinished
            lock.unlock()
            // The run may have completed in the instant between the last poll
            // and the deadline. Killing then would turn a successful run into
            // a failed one at the very last moment.
            guard !finished else { return }
            onExpiry(expiry)
        }
        thread.name = "multiemu run deadline"
        // The thread sleeps and compares dates; the default 512 KB stack is
        // already generous for that.
        thread.stackSize = 512 * 1024
        thread.start()
    }
}
