import Foundation

/// Makes a booted Android guest reachable over ADB.
///
/// **Why any of this is needed.** adbd is running and listening the whole time;
/// what is missing is a route back. Cuttlefish names its ethernet
/// `buried_eth0`, leaves it down, and deliberately keeps it out of Android's
/// connectivity stack. Bringing it up and addressing it is not enough, because
/// Android uses policy routing and its rule set contains no `lookup main` at
/// all — it ends in `32000: from all unreachable`. The on-link route the kernel
/// installs with the address lands in `main` and is never consulted, so the
/// host's SYN arrives (the interface's `rx_packets` counts it) and no SYN-ACK
/// is ever routed back. The fix is one route in the `local_network` table.
///
/// That diagnosis cost this project a wrong conclusion first — "the image has
/// no `virtio_net`", reached by reading a truncated `ip addr` — so the reason
/// is recorded here rather than in a commit message.
///
/// **This drives a root shell.** Everything below runs as root inside the
/// guest. The vocabulary is fixed and composed here; no part of it comes from
/// the guest, a file, or a user field. See `GuestConsoleShell`.
public enum GuestADBEnablement {

    public struct Configuration: Sendable, Equatable {
        /// Cuttlefish's name for the ethernet it does not manage.
        public var interfaceName: String
        /// The address QEMU's user-mode network hands out. Fixed by slirp.
        public var address: String
        public var subnet: String
        /// The table Android's rules actually consult for unmarked traffic.
        public var routingTable: String
        public var guestPort: Int

        public init(interfaceName: String = "buried_eth0",
                    address: String = "10.0.2.15/24",
                    subnet: String = "10.0.2.0/24",
                    routingTable: String = "local_network",
                    guestPort: Int = 5555) {
            self.interfaceName = interfaceName
            self.address = address
            self.subnet = subnet
            self.routingTable = routingTable
            self.guestPort = guestPort
        }
    }

    /// One step, with the reason it exists.
    public struct Step: Sendable, Equatable {
        public let purpose: String
        public let command: String
    }

    /// The ordered steps, as data, so the sequence can be read and tested
    /// without a guest to run it against.
    public static func steps(for configuration: Configuration = Configuration()) -> [Step] {
        [
            Step(purpose: "bring the interface up",
                 command: "su 0 ip link set \(configuration.interfaceName) up"),
            Step(purpose: "give it the address QEMU's network expects",
                 command: "su 0 ip addr add \(configuration.address) dev \(configuration.interfaceName)"),
            // The one that actually fixes the hang.
            Step(purpose: "route replies through the table Android consults",
                 command: "su 0 ip route add \(configuration.subnet) dev \(configuration.interfaceName) "
                        + "table \(configuration.routingTable)"),
            Step(purpose: "tell adbd to serve TCP",
                 command: "su 0 setprop service.adb.tcp.port \(configuration.guestPort)"),
            Step(purpose: "restart adbd so it picks the port up",
                 command: "su 0 stop adbd"),
            Step(purpose: "start adbd again",
                 command: "su 0 start adbd"),
        ]
    }

    public struct Outcome: Sendable, Equatable {
        /// What adbd reports its TCP port as, read back rather than assumed.
        public var servingPort: Int?
        /// init's view of adbd after the restart.
        public var adbdState: String?
        public var configuredPort: Int

        /// True only when the guest itself confirms both halves.
        ///
        /// A step that ran is not a step that worked: `setprop` fails silently
        /// when the caller may not set the property, and this project has
        /// already shipped one "success" that was never verified.
        public var isServing: Bool {
            servingPort == configuredPort && adbdState == "running"
        }

        public var summary: String {
            guard isServing else {
                return "ADB is not serving: adbd is \(adbdState ?? "in an unknown state") "
                    + "and its TCP port reads \(servingPort.map(String.init) ?? "unset")"
            }
            return "adbd is serving TCP on guest port \(configuredPort)"
        }
    }

    /// Runs the steps and asks the guest whether they took.
    ///
    /// Blocking. Run it off the cooperative thread pool.
    public static func perform(
        over session: GuestConsoleShell.Session,
        configuration: Configuration = Configuration()
    ) -> Outcome {
        for step in steps(for: configuration) {
            session.run(step.command)
        }
        let port = session.value(of: "getprop service.adb.tcp.port").flatMap(Int.init)
        let state = session.value(of: "getprop init.svc.adbd")
        return Outcome(servingPort: port, adbdState: state, configuredPort: configuration.guestPort)
    }
}
