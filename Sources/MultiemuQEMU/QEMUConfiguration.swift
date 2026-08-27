import Foundation
import MultiemuBackend
import MultiemuSupport

/// Everything needed to launch one QEMU process.
///
/// A value type on purpose: the configuration is built, validated and logged
/// before anything is spawned, and the exact argument vector that resulted is
/// recorded in the diagnostics bundle. "What command did we actually run" is the
/// first question of every emulator support case, and it must never require
/// reconstructing state after the fact.
public struct QEMUConfiguration: Sendable, Equatable {

    public enum Display: Sendable, Equatable {
        /// No display device at all. Used for headless boot verification.
        case none
        /// virtio-gpu, 2D. Verified to attach on `-machine virt` with HVF in
        /// Milestone 2. The first graphics milestone target.
        case virtioGPU(widthInPixels: Int, heightInPixels: Int)

        /// virtio-gpu plus QEMU's D-Bus display backend, which exports scanouts
        /// to an external process — the candidate out-of-process frame path for
        /// Milestone 5.
        ///
        /// `peerToPeer` selects `p2p=on`, which needs no session bus. That
        /// matters on macOS: plain `-display dbus` fails with
        /// "Cannot spawn a message bus without a machine-id", while
        /// `-display dbus,p2p=on` initialises. (`VERIFY.md` → `QEMU-DBUS-DISPLAY-MACOS`)
        ///
        /// There is deliberately no `vhostUserGPU` case: Milestone 2 established
        /// that `vhost-user-gpu-pci` is not a valid device model on macOS, so
        /// offering it in the type would imply a capability that does not exist.
        case dbusDisplay(peerToPeer: Bool, widthInPixels: Int, heightInPixels: Int)
    }

    public enum Serial: Sendable, Equatable {
        /// Guest console on our stdout. Simplest, used by the boot experiment.
        case stdio
        /// Guest console on a UNIX socket we create.
        case unixSocket(path: String)
    }

    public struct Drive: Sendable, Equatable {
        public enum Format: String, Sendable { case raw, qcow2 }

        public var id: String
        public var url: URL
        public var format: Format
        public var readOnly: Bool

        /// Stable block-node name.
        ///
        /// Snapshots address block nodes by name, and QEMU otherwise assigns
        /// generated names like `#block001` that change between runs — which
        /// would make a snapshot command written for one launch wrong on the
        /// next.
        ///
        /// Must differ from `id`: QEMU keeps drive identifiers and block node
        /// names in **one namespace**, and reusing the same string fails with
        /// "Device name 'x' conflicts with an existing node name". The default
        /// therefore suffixes rather than reusing the identifier.
        public var nodeName: String

        public init(id: String, url: URL, format: Format, readOnly: Bool, nodeName: String? = nil) {
            self.id = id
            self.url = url
            self.format = format
            self.readOnly = readOnly
            self.nodeName = nodeName ?? "\(id)-node"
        }
    }

    public struct PortForward: Sendable, Equatable {
        public var hostPort: Int
        public var guestPort: Int

        public init(hostPort: Int, guestPort: Int) {
            self.hostPort = hostPort
            self.guestPort = guestPort
        }
    }

    /// One virtio-console port.
    public struct ConsolePort: Sendable, Equatable {
        public enum Backend: Sendable, Equatable {
            /// Present but silent: reads never return, writes are discarded.
            /// Enough for a guest that only needs the node to exist.
            case null
            /// A UNIX socket on the host, for a port something must answer on.
            /// QEMU listens; the responder connects.
            case unixSocket(path: String)
        }

        public var backend: Backend

        public init(backend: Backend = .null) {
            self.backend = backend
        }

        /// A bank of `count` silent ports, which is what most images want.
        public static func silentBank(count: Int) -> [ConsolePort] {
            Array(repeating: ConsolePort(backend: .null), count: count)
        }
    }

    public var executableURL: URL
    public var guestArchitecture: GuestArchitecture
    public var acceleration: AccelerationMode
    public var vcpuCount: Int
    public var memoryBytes: UInt64

    public var kernelURL: URL?
    public var initialRamdiskURL: URL?
    public var kernelCommandLine: [String]

    public var drives: [Drive]
    public var portForwards: [PortForward]
    public var includeNetworkDevice: Bool
    /// Host directories exported to the guest over 9p.
    public var sharedFolders: [SharedFolder] = []

    /// How guest audio leaves the machine, if at all.
    ///
    /// The device is USB audio on an xHCI controller, and that is not a
    /// preference. QEMU 11.1.0 on macOS builds `intel-hda`, `AC97` and
    /// `usb-audio` and **no virtio-sound at all**; of those, the Cuttlefish
    /// Android kernel binds only USB audio. Attaching all three and asking the
    /// guest what it enumerated produced one card — `QEMU USB Audio` — with a
    /// playback node at `/dev/snd/pcmC0D0p`. See `scripts/check-guest-audio.sh`.
    public enum Audio: Sendable, Equatable {
        /// No audio device at all.
        case none
        /// Play through the host's default output.
        case coreAudio
        /// Write what the guest plays to a WAV file.
        ///
        /// Not a toy: it is what makes "did any audio arrive" answerable
        /// without a person listening, and it is how the output path was
        /// verified in the first place.
        case wavFile(path: String)
        /// Carry audio over the same D-Bus channel as frames.
        ///
        /// Pairs with `org.qemu.Display1.Audio` and needs `-display dbus`.
        case dbus
    }

    public var audio: Audio

    public var display: Display
    /// Attach virtio keyboard and tablet devices.
    ///
    /// A tablet rather than a mouse: it reports absolute coordinates, which is
    /// what a touch-first Android guest expects and what lets a host pointer
    /// position map directly to a guest pixel.
    public var includeInputDevices: Bool
    public var serial: Serial
    /// virtio-console ports, surfacing in the guest as `/dev/hvc0`, `/dev/hvc1`,
    /// and so on in this order.
    ///
    /// Android images built for a virtual board expect a bank of these and are
    /// handed one per HAL that talks to the host. A HAL whose port is missing
    /// fails on `ENOENT` and, if its interface is declared in VINTF,
    /// `system_server` then waits on it forever — a stall that looks nothing
    /// like a missing device. Ports are cheap, so it is better to supply the
    /// whole bank than to guess which indices an image uses.
    public var consolePorts: [ConsolePort]
    public var qmpSocketPath: String?

    /// Stop instead of rebooting, so a guest panic surfaces as an exit rather
    /// than an invisible boot loop. Correct default for every automated test.
    public var stopOnGuestReboot: Bool

    /// Escape hatch, appended verbatim after everything else. Kept for
    /// experiments; never populated from guest-supplied data.
    public var extraArguments: [String]

    public init(
        executableURL: URL,
        guestArchitecture: GuestArchitecture,
        acceleration: AccelerationMode,
        vcpuCount: Int,
        memoryBytes: UInt64,
        kernelURL: URL? = nil,
        initialRamdiskURL: URL? = nil,
        kernelCommandLine: [String] = [],
        drives: [Drive] = [],
        portForwards: [PortForward] = [],
        includeNetworkDevice: Bool = true,
        sharedFolders: [SharedFolder] = [],
        display: Display = .none,
        audio: Audio = .none,
        includeInputDevices: Bool = false,
        serial: Serial = .stdio,
        consolePorts: [ConsolePort] = [],
        qmpSocketPath: String? = nil,
        stopOnGuestReboot: Bool = true,
        extraArguments: [String] = []
    ) {
        self.executableURL = executableURL
        self.guestArchitecture = guestArchitecture
        self.acceleration = acceleration
        self.vcpuCount = vcpuCount
        self.memoryBytes = memoryBytes
        self.kernelURL = kernelURL
        self.initialRamdiskURL = initialRamdiskURL
        self.kernelCommandLine = kernelCommandLine
        self.drives = drives
        self.portForwards = portForwards
        self.includeNetworkDevice = includeNetworkDevice
        self.sharedFolders = sharedFolders
        self.display = display
        self.audio = audio
        self.includeInputDevices = includeInputDevices
        self.serial = serial
        self.consolePorts = consolePorts
        self.qmpSocketPath = qmpSocketPath
        self.stopOnGuestReboot = stopOnGuestReboot
        self.extraArguments = extraArguments
    }

    /// How a backend-level audio choice becomes a QEMU one.
    ///
    /// Public and separate from `QEMUBackend` so the mapping can be tested
    /// without starting a guest. It is one line, and one line is exactly the
    /// kind of thing that gets silently reversed.
    public static func audio(for mode: GuestAudioMode) -> Audio {
        switch mode {
        case .disabled: return .none
        // CoreAudio rather than the D-Bus backend: `dbus` would need a client
        // for `org.qemu.Display1.Audio`, and this project has not written one,
        // so choosing it would send guest audio nowhere while looking wired.
        case .hostOutput: return .coreAudio
        }
    }

    /// Canonical executable name for a guest architecture.
    public static func executableName(for architecture: GuestArchitecture) -> String {
        switch architecture {
        case .arm64: return "qemu-system-aarch64"
        case .x86_64: return "qemu-system-x86_64"
        }
    }
}
