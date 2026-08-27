import Testing
@testable import MultiemuGuestServices

@Suite("Enabling ADB inside the guest")
struct GuestADBEnablementTests {

    @Test("The route into Android's own table is part of the sequence")
    func includesThePolicyRoute() {
        let steps = GuestADBEnablement.steps()
        // This is the step the whole milestone turned on. Addressing an
        // interface is not enough: Android's rules never consult `main`, so
        // without a route in `local_network` the SYN arrives and nothing is
        // ever routed back.
        #expect(steps.contains { $0.command.contains("table local_network") })
    }

    @Test("The interface is up and addressed before the route is added")
    func ordersTheStepsCorrectly() {
        let commands = GuestADBEnablement.steps().map(\.command)
        let up = try! #require(commands.firstIndex { $0.contains("link set") })
        let address = try! #require(commands.firstIndex { $0.contains("addr add") })
        let route = try! #require(commands.firstIndex { $0.contains("route add") })
        let port = try! #require(commands.firstIndex { $0.contains("setprop service.adb.tcp.port") })
        let restart = try! #require(commands.lastIndex { $0.contains("start adbd") })
        #expect(up < address)
        #expect(address < route, "a route cannot be added to an unaddressed interface")
        #expect(port < restart, "adbd reads the port when it starts, not while running")
    }

    @Test("Configuration reaches every command that depends on it")
    func configurationIsHonoured() {
        let configuration = GuestADBEnablement.Configuration(
            interfaceName: "eth7", address: "10.9.9.9/24", subnet: "10.9.9.0/24",
            routingTable: "other_table", guestPort: 5599)
        let commands = GuestADBEnablement.steps(for: configuration).map(\.command)
        #expect(commands.contains { $0.contains("eth7") && $0.contains("link set") })
        #expect(commands.contains { $0.contains("10.9.9.9/24") })
        #expect(commands.contains { $0.contains("10.9.9.0/24") && $0.contains("table other_table") })
        #expect(commands.contains { $0.contains("service.adb.tcp.port 5599") })
    }

    @Test("Success is only claimed when the guest confirms both halves")
    func outcomeRequiresConfirmation() {
        // `setprop` fails silently for a caller that may not set the property,
        // so a step that ran is not a step that worked.
        #expect(GuestADBEnablement.Outcome(
            servingPort: 5555, adbdState: "running", configuredPort: 5555).isServing)
        #expect(GuestADBEnablement.Outcome(
            servingPort: 5555, adbdState: "restarting", configuredPort: 5555).isServing == false)
        #expect(GuestADBEnablement.Outcome(
            servingPort: nil, adbdState: "running", configuredPort: 5555).isServing == false)
        #expect(GuestADBEnablement.Outcome(
            servingPort: 5037, adbdState: "running", configuredPort: 5555).isServing == false,
            "a port that is not the one asked for is not success")
    }

    @Test("A failure explains itself rather than saying only that it failed")
    func failureSummaryNamesWhatWasSeen() {
        let outcome = GuestADBEnablement.Outcome(
            servingPort: nil, adbdState: "stopped", configuredPort: 5555)
        #expect(outcome.summary.contains("stopped"))
        #expect(outcome.summary.contains("unset"))
    }
}
