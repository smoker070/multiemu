import Testing

@testable import MultiemuGuestServices

@Suite("Quiescing guest services this host cannot support")
struct GuestServiceQuiesceTests {

    private let radio = UnsupportedGuestService(
        initServiceName: "vendor.ril-daemon", reason: "no vsock on this host")
    private let thread = UnsupportedGuestService(
        initServiceName: "vendor.threadnetwork_hal", reason: "no eth1 in this guest")

    @Test("A service init is crash-looping is stopped")
    func restartingIsStopped() {
        let decisions = GuestServiceQuiesce.decisions(
            for: [radio], state: ["vendor.ril-daemon": "restarting"])
        #expect(decisions == [.stop(radio)])
    }

    @Test("A running service is never stopped, even though it is on the list")
    func runningIsLeftAlone() {
        // The safety property the whole design rests on. The list names
        // services that cannot work *on this host*; the day an image or a host
        // makes one work, it must survive untouched rather than be disabled by
        // a list nobody revisited.
        let decisions = GuestServiceQuiesce.decisions(
            for: [radio], state: ["vendor.ril-daemon": "running"])
        #expect(decisions == [.leave(service: radio, state: "running")])
    }

    @Test("A service that is already stopped is left alone")
    func stoppedIsLeftAlone() {
        let decisions = GuestServiceQuiesce.decisions(
            for: [radio], state: ["vendor.ril-daemon": "stopped"])
        #expect(decisions == [.leave(service: radio, state: "stopped")])
    }

    @Test("A state that could not be read is not treated as a crash loop")
    func unreadableStateIsLeftAlone() {
        // A console that answered nothing is not evidence of anything. Reading
        // silence as "restarting" would stop services on every guest whose
        // console was busy at the wrong moment.
        let decisions = GuestServiceQuiesce.decisions(for: [radio, thread], state: [:])
        #expect(decisions == [.leave(service: radio, state: nil), .leave(service: thread, state: nil)])
    }

    @Test("Each service is judged on its own state")
    func servicesAreJudgedIndependently() {
        let decisions = GuestServiceQuiesce.decisions(
            for: [radio, thread],
            state: ["vendor.ril-daemon": "restarting", "vendor.threadnetwork_hal": "running"])
        #expect(decisions == [.stop(radio), .leave(service: thread, state: "running")])
    }

    @Test("An almost-matching state does not count as restarting")
    func stateMatchIsExact() {
        // init has one word for this. Anything else — a truncated read, a
        // different init, a state this code has not seen — is not it.
        for state in ["restart", "restarting_", "RESTARTING", "running (restarting soon)"] {
            let decisions = GuestServiceQuiesce.decisions(
                for: [radio], state: ["vendor.ril-daemon": state])
            #expect(decisions == [.leave(service: radio, state: state)], "\(state) must not be stopped")
        }
    }

    @Test("The shipped list names only services with a recorded reason")
    func shippedListCarriesReasons() {
        #expect(!GuestServiceQuiesce.cuttlefishServices.isEmpty)
        for service in GuestServiceQuiesce.cuttlefishServices {
            #expect(!service.reason.isEmpty, "\(service.initServiceName) has no reason")
            #expect(service.initServiceName.hasPrefix("vendor."))
        }
    }

    @Test("The outcome says what happened, including what it could not do")
    func outcomeSummarises() {
        var outcome = GuestServiceQuiesce.Outcome()
        #expect(outcome.summary == "nothing to quiesce")
        outcome.stopped = ["vendor.ril-daemon"]
        outcome.refused = ["vendor.threadnetwork_hal"]
        outcome.leftPairs = [("vendor.other", "running")]
        #expect(outcome.summary.contains("stopped vendor.ril-daemon"))
        #expect(outcome.summary.contains("could not stop vendor.threadnetwork_hal"))
        #expect(outcome.summary.contains("left vendor.other (running)"))
    }
}
