import Darwin
import Foundation
import MultiemuSupport

/// How a guest reaches the network.
public struct GuestNetworkConfiguration: Sendable, Equatable, Codable {

    public enum Mode: String, Sendable, Codable, CaseIterable {
        /// User-mode networking (libslirp). Unprivileged, NAT-style, and the
        /// only default. The guest reaches outward; nothing reaches in except
        /// through explicit forwards.
        case userMode
        /// No network device at all.
        case disabled
        /// Bridged to a host interface. Requires elevated privileges — Milestone
        /// 2 confirmed QEMU's `vmnet-*` backends fail unprivileged — so it stays
        /// behind an explicit opt-in and a privileged helper.
        case bridged
    }

    /// A forwarded TCP or UDP port.
    ///
    /// Always bound to loopback. A forwarded port on a wildcard address exposes
    /// the guest — and ADB, once Milestone 8 lands — to everything on the local
    /// network, which the product constraints forbid.
    public struct PortForward: Sendable, Equatable, Codable {
        public enum NetworkProtocol: String, Sendable, Codable { case tcp, udp }

        public var label: String
        public var hostPort: Int
        public var guestPort: Int
        public var networkProtocol: NetworkProtocol

        public init(label: String, hostPort: Int, guestPort: Int, networkProtocol: NetworkProtocol = .tcp) {
            self.label = label
            self.hostPort = hostPort
            self.guestPort = guestPort
            self.networkProtocol = networkProtocol
        }
    }

    public var mode: Mode
    public var portForwards: [PortForward]

    public init(mode: Mode = .userMode, portForwards: [PortForward] = []) {
        self.mode = mode
        self.portForwards = portForwards
    }

    public static let `default` = GuestNetworkConfiguration()

    /// Addresses libslirp presents to the guest. Fixed by libslirp, listed here
    /// so diagnostics can explain what the guest should be seeing.
    public enum UserModeAddresses {
        public static let guest = "10.0.2.15"
        public static let gateway = "10.0.2.2"
        public static let dnsServer = "10.0.2.3"
        public static let netmask = "255.255.255.0"
    }

    /// Ports below this are privileged on macOS and must never be requested.
    public static let firstUnprivilegedPort = 1024

    /// Problems with this configuration.
    ///
    /// `claimedHostPorts` are ports other **running** devices already forward.
    /// Checking only within one device was enough while one could run; with
    /// several, the clash is between devices and QEMU reports it as an opaque
    /// bind failure at launch.
    public func problems(claimedHostPorts: Set<Int> = []) -> [String] {
        var problems: [String] = []
        var seenHostPorts = Set<Int>()

        for forward in portForwards {
            if claimedHostPorts.contains(forward.hostPort) {
                problems.append("""
                    Forward \"\(forward.label)\" asks for host port \(forward.hostPort), which another \
                    running device is already using. Stop that device, or give this one a different port.
                    """)
            }
            if forward.hostPort < Self.firstUnprivilegedPort {
                problems.append("""
                    Forward \"\(forward.label)\" asks for host port \(forward.hostPort), which is privileged. \
                    Multiemu never requests elevated privileges for networking.
                    """)
            }
            guard (1...65535).contains(forward.hostPort), (1...65535).contains(forward.guestPort) else {
                problems.append("Forward \"\(forward.label)\" has a port outside 1–65535.")
                continue
            }
            if !seenHostPorts.insert(forward.hostPort).inserted {
                problems.append("Host port \(forward.hostPort) is claimed by more than one forward.")
            }
        }

        if mode == .disabled, !portForwards.isEmpty {
            problems.append("Port forwards were configured but networking is disabled.")
        }
        if mode == .bridged {
            problems.append("""
                Bridged networking requires elevated privileges and a privileged helper, \
                which Multiemu does not yet provide. Use user-mode networking.
                """)
        }
        return problems
    }
}

/// Finds free loopback ports for guest forwards.
///
/// Needed from Milestone 8 onward: every running device needs its own ADB port,
/// and hard-coding 5555 makes a second instance fail in a way that looks like a
/// broken emulator rather than a port clash.
public enum HostPortAllocator {

    public enum Failure: Error, Sendable, CustomStringConvertible {
        case noFreePort(attempts: Int)

        public var description: String {
            switch self {
            case let .noFreePort(attempts):
                return "Could not find a free loopback port after \(attempts) attempts."
            }
        }
    }

    /// Asks the kernel for an unused port by binding to port 0 on loopback.
    ///
    /// Inherently racy — the port could be taken between here and QEMU binding
    /// it — but it is the only portable way to ask, and the alternative of
    /// scanning a fixed range races just as badly while also colliding with
    /// other applications. Callers should treat a bind failure as retryable.
    public static func allocate(excluding reserved: Set<Int> = []) throws -> Int {
        for _ in 1...32 {
            guard let port = probeEphemeralPort() else { continue }
            if reserved.contains(port) { continue }
            return port
        }
        throw Failure.noFreePort(attempts: 32)
    }

    /// True when a port can currently be bound on loopback.
    public static func isAvailable(_ port: Int) -> Bool {
        bindProbe(port: UInt16(port)) != nil
    }

    private static func probeEphemeralPort() -> Int? {
        bindProbe(port: 0)
    }

    /// Binds, reads back the assigned port, and closes.
    private static func bindProbe(port: UInt16) -> Int? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        // Loopback only, matching how the forward will actually be bound.
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: actual.sin_port))
    }
}
