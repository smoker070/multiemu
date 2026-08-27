import Foundation
import MultiemuSupport

/// One disk attached to a guest.
///
/// The format is explicit rather than probed from the file's contents. QEMU
/// documents format probing as a security hazard — a raw image whose first
/// bytes happen to look like a qcow2 header would be interpreted as one, and a
/// guest can write those bytes itself. The caller always knows the format, so
/// it is carried here.
public struct GuestDiskImage: Sendable, Equatable {
    public enum Format: String, Sendable, Codable, Equatable {
        case raw
        case qcow2
    }

    public var url: URL
    public var format: Format
    public var isReadOnly: Bool

    public init(url: URL, format: Format, isReadOnly: Bool) {
        self.url = url
        self.format = format
        self.isReadOnly = isReadOnly
    }
}

/// Whether the guest presents a display, and how large.
public enum GuestDisplayMode: Sendable, Equatable {
    /// No graphics device. Used for boot verification and headless work.
    case headless
    /// virtio-gpu plus QEMU's D-Bus display, so Multiemu receives frames, and
    /// virtio input devices so it can send events back.
    ///
    /// `framebufferSide` is the square the GPU is allocated at boot. A guest
    /// cannot later select a mode larger than the EDID built from it, per axis,
    /// so this is what decides which resolutions and rotations can be applied
    /// without restarting. Defaults to the requested mode, which permits no
    /// growth — callers that want runtime changes must ask for more.
    case attached(widthInPixels: Int, heightInPixels: Int, framebufferSide: Int? = nil)

    /// The square to allocate at boot.
    public var bootFramebufferSide: Int? {
        guard case let .attached(width, height, side) = self else { return nil }
        return max(side ?? 0, width, height)
    }
}

/// What a virtual device needs in order to start.
///
/// Deliberately describes *intent*, not a command line. A backend translates
/// this into whatever its engine needs; nothing here mentions QEMU.
/// A virtio-console port offered to the guest, and what answers on it.
///
/// Android images built for a virtual board expect a bank of these and hand one
/// to each HAL that talks to a host service. A port that is missing fails the
/// HAL on `ENOENT`; a port that exists but never answers is worse, because a
/// HAL blocked in `read()` never registers its interface and `system_server`
/// then waits on it for the life of the boot.
public struct GuestConsolePort: Sendable, Equatable {

    public enum Service: String, Sendable, Equatable, Codable {
        /// Present but silent. Enough for a HAL that only needs the node to
        /// exist, and for the ports nothing has claimed.
        case silent
        /// The goldfish `qemud` sensors protocol. The guest's sensors HAL will
        /// not register `android.hardware.sensors.ISensors` until this is
        /// answered.
        case sensors
        /// The shell Android starts when `androidboot.console` names this port.
        ///
        /// Unlike the others the host is the *client* here, and what it gets is
        /// a root shell. It exists because some guest configuration has no
        /// channel from outside — see `GuestServiceQuiesce`. Give the port a
        /// socket only on a guest whose command line actually names it, and
        /// treat everything sent through it as the privileged operation it is.
        case androidConsole
    }

    public var service: Service

    public init(service: Service = .silent) {
        self.service = service
    }

    /// A bank of silent ports, with specific indices claimed by services.
    ///
    /// Indices are the guest's `/dev/hvcN` numbers, so which index carries what
    /// is a property of the image and belongs with whoever knows the image —
    /// not baked into the backend.
    ///
    /// Throws rather than dropping a service whose index falls outside the
    /// bank. Silently ignoring it produced the worst failure this component
    /// has: no responder, no warning, and a guest that stalls until the boot
    /// watchdog reports a timeout naming nothing in particular.
    public static func bank(count: Int, services: [Int: Service]) throws -> [GuestConsolePort] {
        if let stray = services.keys.first(where: { $0 < 0 || $0 >= count }) {
            throw MultiemuError.invalidConfiguration(
                field: "Console ports",
                detail: """
                    A service was assigned to port \(stray), but only \(count) ports were \
                    requested (0...\(count - 1)). The guest would never see it.
                    """
            )
        }
        return (0..<count).map { GuestConsolePort(service: services[$0] ?? .silent) }
    }
}

/// Whether a guest gets a sound device, and where its output goes.
///
/// Deliberately not a list of QEMU backends. The backend layer decides which
/// device can carry it — on QEMU/macOS that is USB audio, because it is the
/// only audio device the Android images this project runs actually bind.
public enum GuestAudioMode: String, Sendable, Equatable, Codable {
    /// No sound device at all.
    case disabled
    /// Play through the host's default output.
    ///
    /// Output only. Capture would need a device this guest cannot drive *and*
    /// microphone permission from the user, and neither is implied by wanting
    /// to hear a guest.
    case hostOutput
}

public struct GuestStartRequest: Sendable, Equatable {
    public var guestArchitecture: GuestArchitecture
    public var acceleration: AccelerationMode
    public var resources: GuestResourceRequest

    public var kernelURL: URL?
    public var initialRamdiskURL: URL?
    public var kernelCommandLine: [String]
    public var disks: [GuestDiskImage]

    /// Whether the guest presents a display.
    public var displayMode: GuestDisplayMode
    /// How the guest reaches the network.
    public var network: GuestNetworkConfiguration
    /// Host directories offered to the guest. Empty by default: a guest reaches
    /// nothing on the host unless the user chose a directory for it.
    public var sharedFolders: [SharedFolder] = []
    /// Host loopback port forwarded to the guest's ADB port, if any.
    public var adbHostPort: Int?
    /// Whether the guest gets a sound device.
    public var audio: GuestAudioMode = .disabled
    /// virtio-console ports, in the order the guest numbers them `/dev/hvc0..`.
    /// Empty by default: a guest gets no console ports unless its image needs them.
    public var consolePorts: [GuestConsolePort] = []
    /// Give up if no terminal boot milestone is reached within this.
    public var bootTimeout: Duration

    public init(
        guestArchitecture: GuestArchitecture,
        acceleration: AccelerationMode,
        resources: GuestResourceRequest,
        kernelURL: URL? = nil,
        initialRamdiskURL: URL? = nil,
        kernelCommandLine: [String] = [],
        disks: [GuestDiskImage] = [],
        displayMode: GuestDisplayMode = .headless,
        network: GuestNetworkConfiguration = .default,
        adbHostPort: Int? = nil,
        audio: GuestAudioMode = .disabled,
        consolePorts: [GuestConsolePort] = [],
        bootTimeout: Duration = .seconds(120)
    ) {
        self.guestArchitecture = guestArchitecture
        self.acceleration = acceleration
        self.resources = resources
        self.kernelURL = kernelURL
        self.initialRamdiskURL = initialRamdiskURL
        self.kernelCommandLine = kernelCommandLine
        self.disks = disks
        self.displayMode = displayMode
        self.network = network
        self.adbHostPort = adbHostPort
        self.audio = audio
        self.consolePorts = consolePorts
        self.bootTimeout = bootTimeout
    }
}

/// Why a guest stopped working.
///
/// `failed` is a state with a retained reason, not an exception that unwinds.
/// The application must be able to show *why* long after the backend process is
/// gone, so everything needed for that is captured here at the moment of failure.
public struct GuestFailure: Sendable, Equatable {

    public enum Kind: String, Sendable, Codable {
        /// The backend executable could not be started at all.
        case backendLaunchFailed
        /// The backend process exited when we did not ask it to.
        case backendTerminatedUnexpectedly
        /// The guest kernel panicked or could not mount its root filesystem.
        case guestPanicked
        /// No terminal boot milestone within the deadline.
        case bootTimedOut
        /// The control channel died while the backend was still running.
        case controlChannelLost
        /// Host resources were insufficient; nothing was started.
        case resourcePreflightFailed
    }

    public var kind: Kind
    /// One line, suitable for a UI.
    public var summary: String
    /// Everything we know, for the diagnostics bundle.
    public var detail: String
    public var backendExitCode: Int32?
    /// The last console lines before the failure — the single most useful
    /// artifact when diagnosing a guest that died.
    public var consoleTail: [String]
    public var lastBootMilestone: BootMilestone.Kind?

    public init(
        kind: Kind,
        summary: String,
        detail: String,
        backendExitCode: Int32? = nil,
        consoleTail: [String] = [],
        lastBootMilestone: BootMilestone.Kind? = nil
    ) {
        self.kind = kind
        self.summary = summary
        self.detail = detail
        self.backendExitCode = backendExitCode
        self.consoleTail = consoleTail
        self.lastBootMilestone = lastBootMilestone
    }
}

/// The guest lifecycle state machine.
///
/// Transitions are documented in `docs/ARCHITECTURE.md`. `failed` is terminal
/// until an explicit restart; it never auto-clears, because a failure the user
/// did not see is a failure that will be reported as "it just stopped working".
public enum GuestRunState: Sendable, Equatable {
    case inactive
    case starting
    case booting(lastMilestone: BootMilestone.Kind?)
    case running
    case stopping
    case failed(GuestFailure)

    public var isActive: Bool {
        switch self {
        case .starting, .booting, .running, .stopping: return true
        case .inactive, .failed: return false
        }
    }

    public var failure: GuestFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }

    public var displayName: String {
        switch self {
        case .inactive: return "Stopped"
        case .starting: return "Starting"
        case .booting(let milestone): return milestone.map { "Booting (\($0.rawValue))" } ?? "Booting"
        case .running: return "Running"
        case .stopping: return "Shutting down"
        case .failed(let failure): return "Failed: \(failure.summary)"
        }
    }
}

/// Everything a backend reports upward.
///
/// No case mentions QEMU, QMP or Virtualization.framework. A backend
/// notification arrives as a name plus text so that engine-specific events can
/// be surfaced in diagnostics without leaking an engine type into this module.
public enum BackendEvent: Sendable, Equatable {
    case stateChanged(GuestRunState)
    case bootMilestone(BootMilestone)
    case consoleLine(String)
    case backendMessage(String)
    case backendNotification(name: String, detail: String)
}

/// The contract every emulator engine implements.
///
/// An `Actor` rather than a class: a backend owns a child process, a control
/// socket and a state machine, all of which are mutated from timers, socket
/// reads and user actions concurrently. Actor isolation is the cheapest correct
/// answer, and it makes the whole surface `async` — which is what allows an XPC
/// transport to be slid underneath later without changing a single call site.
public protocol EmulatorBackend: Actor {
    static var descriptor: BackendDescriptor { get }

    var state: GuestRunState { get }

    /// Events, in order. Created once at initialisation and valid for the
    /// lifetime of the backend, including across guest restarts.
    nonisolated var events: AsyncStream<BackendEvent> { get }

    /// Starts the engine and drives the guest to `running`.
    /// Throws only for failures detectable before the engine starts; everything
    /// after that surfaces as `.failed` state plus an event.
    func start(_ request: GuestStartRequest) async throws

    /// Asks the guest to shut down, escalating if it does not comply.
    func requestShutdown(timeout: Duration) async

    /// Stops the engine immediately, without asking the guest.
    func terminate() async

    /// The last console lines, for diagnostics.
    func recentConsole(limit: Int) -> [String]

    // MARK: Snapshots
    //
    // Deliberately left off this protocol in Milestone 3, because their shape
    // depended on qcow2 and QMP behaviour that had not been exercised. It has
    // been now, so the contract is committed here — with default
    // implementations, so a backend that cannot snapshot says so rather than
    // being forced to pretend.

    /// Captures RAM and disk state under `tag`.
    func captureSnapshot(tag: String) async throws -> SnapshotHandle
    /// Returns the guest to a previously captured state.
    func restoreSnapshot(tag: String) async throws
    func deleteSnapshot(tag: String) async throws
    func listSnapshots() async throws -> [SnapshotHandle]
}

public extension EmulatorBackend {
    func captureSnapshot(tag: String) async throws -> SnapshotHandle {
        throw MultiemuError.backendUnavailable(
            backend: String(describing: Self.self),
            reason: "This backend does not support snapshots."
        )
    }

    func restoreSnapshot(tag: String) async throws {
        throw MultiemuError.backendUnavailable(
            backend: String(describing: Self.self),
            reason: "This backend does not support snapshots."
        )
    }

    func deleteSnapshot(tag: String) async throws {
        throw MultiemuError.backendUnavailable(
            backend: String(describing: Self.self),
            reason: "This backend does not support snapshots."
        )
    }

    func listSnapshots() async throws -> [SnapshotHandle] { [] }
}
