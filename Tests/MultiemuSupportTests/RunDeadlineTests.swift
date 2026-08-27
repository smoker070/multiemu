import Foundation
import Testing
@testable import MultiemuSupport

@Suite("Run deadline")
struct RunDeadlineTests {

    /// Collects expiries from the watchdog thread.
    ///
    /// The callback fires on a thread of the watchdog's own, which is the whole
    /// point of the type, so the test cannot simply append to a local.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var expiries: [RunDeadline.Expiry] = []

        func record(_ expiry: RunDeadline.Expiry) {
            lock.lock(); expiries.append(expiry); lock.unlock()
        }

        var all: [RunDeadline.Expiry] {
            lock.lock(); defer { lock.unlock() }; return expiries
        }
    }

    /// Waits for `condition` to hold, up to `timeout`, without pinning a core.
    private func eventually(
        timeout: Double = 3,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    @Test("A run that overruns its ceiling expires")
    func expiresOnOverrun() {
        let recorder = Recorder()
        let deadline = RunDeadline(limit: 0.2, pollInterval: 0.02) { recorder.record($0) }
        deadline.start()

        #expect(eventually { recorder.all.count == 1 })
        #expect(recorder.all.first?.limit == 0.2)
    }

    @Test("The expiry names the phase the run stalled in")
    func expiryCarriesThePhase() {
        // The message is the only evidence a killed run leaves behind, so the
        // phase has to survive the kill. A ceiling that reports nothing but
        // "timed out" sends the next person back to the start.
        let recorder = Recorder()
        let deadline = RunDeadline(limit: 0.2, pollInterval: 0.02) { recorder.record($0) }
        deadline.enter("sampling frames under the workload")
        deadline.adopt(guestPID: 4242)
        deadline.start()

        #expect(eventually { recorder.all.count == 1 })
        #expect(recorder.all.first?.phase == "sampling frames under the workload")
        #expect(recorder.all.first?.guestPID == 4242)
    }

    @Test("The last phase entered is the one reported")
    func laterPhasesReplaceEarlierOnes() {
        let recorder = Recorder()
        let deadline = RunDeadline(limit: 0.3, pollInterval: 0.02) { recorder.record($0) }
        deadline.enter("settling")
        deadline.start()
        deadline.enter("sampling idle CPU")

        #expect(eventually { recorder.all.count == 1 })
        #expect(recorder.all.first?.phase == "sampling idle CPU")
    }

    @Test("A run that finishes in time is never killed")
    func finishingRetiresTheWatchdog() {
        // The failure this guards against is the harness killing its own
        // successful run — which would look exactly like the stall it exists
        // to report, and would be blamed on the guest.
        let recorder = Recorder()
        let deadline = RunDeadline(limit: 0.2, pollInterval: 0.02) { recorder.record($0) }
        deadline.start()
        deadline.finish()

        Thread.sleep(forTimeInterval: 0.6)   // well past the ceiling
        #expect(recorder.all.isEmpty)
    }

    @Test("A phase with no guest yet expires without a pid to kill")
    func expiresBeforeTheGuestExists() {
        // Setup stalls happen before QEMU has a pid. Reporting 0 lets the
        // caller skip the kill rather than signalling process group 0, which
        // would take the harness's own process down with it.
        let recorder = Recorder()
        let deadline = RunDeadline(limit: 0.2, pollInterval: 0.02) { recorder.record($0) }
        deadline.enter("starting up")
        deadline.start()

        #expect(eventually { recorder.all.count == 1 })
        #expect(recorder.all.first?.guestPID == 0)
    }

    @Test("The default ceiling scales with the phases it has to cover")
    func defaultLimitScalesWithTheFlags() {
        // Derived, not constant: raising --settle must not make a legitimate
        // run trip the backstop.
        let short = RunDeadline.defaultLimit(
            bootCeiling: 180, settleSeconds: 90, idleSeconds: 60, sampleSeconds: 60)
        let long = RunDeadline.defaultLimit(
            bootCeiling: 180, settleSeconds: 600, idleSeconds: 300, sampleSeconds: 60)
        #expect(short == 780)
        #expect(long > short)
    }

    @Test("The default ceiling never falls below the floor")
    func defaultLimitHasAFloor() {
        let tiny = RunDeadline.defaultLimit(
            bootCeiling: 5, settleSeconds: 1, idleSeconds: 1, sampleSeconds: 1)
        #expect(tiny == 300)
    }

    @Test("Killing with no adopted guest is a no-op")
    func killGuestWithoutAGuestIsSafe() {
        // `kill(0, SIGKILL)` signals the caller's whole process group. If this
        // guard ever goes, the test runner dies with it.
        let deadline = RunDeadline(limit: 60, pollInterval: 0.02) { _ in }
        deadline.killGuest()
        deadline.finish()
    }
}
