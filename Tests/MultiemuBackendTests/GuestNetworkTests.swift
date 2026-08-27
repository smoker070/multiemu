import Foundation
import Testing
@testable import MultiemuBackend

@Suite("Guest networking configuration")
struct GuestNetworkTests {

    @Test("User-mode networking with no forwards is valid and is the default")
    func defaultIsValid() {
        #expect(GuestNetworkConfiguration.default.mode == .userMode)
        #expect(GuestNetworkConfiguration.default.problems().isEmpty)
    }

    @Test("Privileged host ports are refused")
    func privilegedPortsRefused() {
        // Multiemu never asks for elevated privileges to network a guest.
        let configuration = GuestNetworkConfiguration(portForwards: [
            .init(label: "http", hostPort: 80, guestPort: 8080)
        ])
        #expect(configuration.problems().contains { $0.contains("privileged") })
    }

    @Test("The first unprivileged port is accepted")
    func boundaryPort() {
        let configuration = GuestNetworkConfiguration(portForwards: [
            .init(label: "edge", hostPort: 1024, guestPort: 5555)
        ])
        #expect(configuration.problems().isEmpty)
    }

    @Test("Two forwards cannot claim the same host port")
    func duplicateHostPorts() {
        let configuration = GuestNetworkConfiguration(portForwards: [
            .init(label: "adb", hostPort: 5555, guestPort: 5555),
            .init(label: "other", hostPort: 5555, guestPort: 8080),
        ])
        #expect(configuration.problems().contains { $0.contains("more than one forward") })
    }

    @Test("The same guest port may be reached from different host ports")
    func sameGuestPortIsFine() {
        let configuration = GuestNetworkConfiguration(portForwards: [
            .init(label: "a", hostPort: 5555, guestPort: 5555),
            .init(label: "b", hostPort: 5556, guestPort: 5555),
        ])
        #expect(configuration.problems().isEmpty)
    }

    @Test("Out-of-range ports are refused")
    func outOfRangePorts() {
        #expect(!GuestNetworkConfiguration(portForwards: [
            .init(label: "high", hostPort: 70000, guestPort: 80)
        ]).problems().isEmpty)
        #expect(!GuestNetworkConfiguration(portForwards: [
            .init(label: "zero", hostPort: 5555, guestPort: 0)
        ]).problems().isEmpty)
    }

    @Test("Forwards without networking are refused rather than silently ignored")
    func forwardsRequireNetworking() {
        let configuration = GuestNetworkConfiguration(mode: .disabled, portForwards: [
            .init(label: "adb", hostPort: 5555, guestPort: 5555)
        ])
        #expect(configuration.problems().contains { $0.contains("networking is disabled") })
    }

    @Test("Bridged networking is refused with the reason, not silently downgraded")
    func bridgedRefused() {
        // Milestone 2 established that QEMU's vmnet backends fail unprivileged.
        // Silently falling back to user-mode would hide a real difference in
        // reachability from the user.
        let problems = GuestNetworkConfiguration(mode: .bridged).problems()
        #expect(problems.contains { $0.contains("elevated privileges") })
    }

    @Test("The libslirp addresses are recorded for diagnostics")
    func slirpAddresses() {
        #expect(GuestNetworkConfiguration.UserModeAddresses.guest == "10.0.2.15")
        #expect(GuestNetworkConfiguration.UserModeAddresses.gateway == "10.0.2.2")
        #expect(GuestNetworkConfiguration.UserModeAddresses.dnsServer == "10.0.2.3")
    }
}

@Suite("Host port allocation")
struct HostPortAllocatorTests {

    @Test("An allocated port is unprivileged and actually bindable")
    func allocatesUsablePort() throws {
        let port = try HostPortAllocator.allocate()
        #expect(port >= GuestNetworkConfiguration.firstUnprivilegedPort)
        #expect(port <= 65535)
        // The kernel just handed it to us, so it must still be free.
        #expect(HostPortAllocator.isAvailable(port))
    }

    @Test("Excluded ports are not returned")
    func honoursExclusions() throws {
        let first = try HostPortAllocator.allocate()
        let second = try HostPortAllocator.allocate(excluding: [first])
        #expect(second != first)
    }

    @Test("A port held by another socket is reported unavailable")
    func detectsBusyPort() throws {
        // Multi-instance depends on this: two devices must not both be told
        // they can have the same ADB port.
        let port = try HostPortAllocator.allocate()
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var reuse: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0)
        #expect(listen(listener, 1) == 0)
        #expect(!HostPortAllocator.isAvailable(port), "a bound port should not be reported available")
    }

    @Test("Repeated allocations do not collide")
    func repeatedAllocationsDiffer() throws {
        var seen = Set<Int>()
        for _ in 0..<8 {
            let port = try HostPortAllocator.allocate(excluding: seen)
            #expect(seen.insert(port).inserted)
        }
    }
}
