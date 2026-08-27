import Foundation
import MultiemuSupport
import Testing
@testable import MultiemuBackend

@Suite("Guest console ports")
struct GuestConsolePortTests {

    @Test("A bank is silent except where a service claims an index")
    func bankAssignsServicesByIndex() throws {
        let ports = try GuestConsolePort.bank(count: 20, services: [18: .sensors])
        #expect(ports.count == 20)
        #expect(ports[18].service == .sensors)
        #expect(ports.filter { $0.service == .sensors }.count == 1)
        #expect(ports.enumerated().allSatisfy { $0.offset == 18 || $0.element.service == .silent })
    }

    @Test("A service assigned past the end of the bank is refused, not dropped")
    func rejectsServiceBeyondTheBank() {
        // The failure this prevents is the worst one this area produces: ten
        // silent ports, no responder, no warning, and a guest that stalls until
        // the boot watchdog reports a timeout naming nothing.
        #expect(throws: MultiemuError.self) {
            _ = try GuestConsolePort.bank(count: 10, services: [18: .sensors])
        }
    }

    @Test("A negative index is refused")
    func rejectsNegativeIndex() {
        #expect(throws: MultiemuError.self) {
            _ = try GuestConsolePort.bank(count: 4, services: [-1: .sensors])
        }
    }

    @Test("The last valid index is accepted")
    func acceptsFinalIndex() throws {
        let ports = try GuestConsolePort.bank(count: 4, services: [3: .sensors])
        #expect(ports[3].service == .sensors)
    }

    @Test("An empty bank with no services is fine")
    func emptyBankIsAllowed() throws {
        #expect(try GuestConsolePort.bank(count: 0, services: [:]).isEmpty)
    }
}
