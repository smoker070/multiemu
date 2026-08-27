import Foundation
import MultiemuBackend
import MultiemuHost
import MultiemuSupport

/// Owns one virtual device's lifetime and survives its backend.
///
/// The split from `EmulatorBackend` is the point of this type. A backend owns
/// mechanism — a process, a socket, a state machine — and dies with them. The
/// session owns policy and history: resource preflight, image validation, the
/// reason the last run failed, how many times we have started, and the
/// configuration needed to start again. When the backend process is killed, the
/// session is what still knows all of that.
///
/// It takes a backend *factory* rather than a backend, for two reasons: a
/// restart needs a fresh backend, and this module must not depend on any
/// concrete engine.
public actor EmulatorSession {

    public struct Configuration: Sendable, Equatable {
        public var deviceName: String
        public var startRequest: GuestStartRequest

        public init(deviceName: String, startRequest: GuestStartRequest) {
            self.deviceName = deviceName
            self.startRequest = startRequest
        }
    }

    public enum SessionEvent: Sendable, Equatable {
        case stateChanged(GuestRunState)
        case bootMilestone(BootMilestone)
        case consoleLine(String)
        case notice(String)
        case preflightWarning(String)
    }

    public private(set) var configuration: Configuration
    public private(set) var state: GuestRunState = .inactive
    /// How many times a backend has been started for this device.
    public private(set) var runCount = 0
    /// Retained across backend death — this is the control state that must not
    /// be lost when the engine crashes.
    public private(set) var lastFailure: GuestFailure?
    public private(set) var lastBootDuration: Duration?
    public private(set) var lastBootTimeline: [BootMilestone] = []

    private let host: HostCapabilities
    /// What other devices have already claimed, asked for at admission time.
    ///
    /// A closure rather than a value because a session outlives any snapshot of
    /// its siblings: devices start and stop while this one sits idle, so a value
    /// captured at construction would be stale exactly when it matters.
    private let committedResources: @Sendable () async -> CommittedResources
    private let backendFactory: @Sendable () -> any EmulatorBackend
    private var backend: (any EmulatorBackend)?
    private var supervision: Task<Void, Never>?
    private var runStartedAt: ContinuousClock.Instant?

    public nonisolated let events: AsyncStream<SessionEvent>
    private nonisolated let eventContinuation: AsyncStream<SessionEvent>.Continuation

    public init(
        configuration: Configuration,
        host: HostCapabilities,
        committedResources: @escaping @Sendable () async -> CommittedResources = { .none },
        backendFactory: @escaping @Sendable () -> any EmulatorBackend
    ) {
        self.configuration = configuration
        self.host = host
        self.committedResources = committedResources
        self.backendFactory = backendFactory
        var captured: AsyncStream<SessionEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(2048)) { captured = $0 }
        self.eventContinuation = captured
    }

    // MARK: - Preflight

    /// Everything checked before a backend is created.
    ///
    /// Image existence is verified here because engine-level validation cannot
    /// be relied on for it: Milestone 2 established that
    /// `VZVirtualMachineConfiguration.validate()` succeeds for a kernel URL that
    /// does not exist. A missing image must fail as a missing image, not as an
    /// unexplained boot timeout two minutes later.
    public func preflight() async -> ResourceValidationResult {
        let committed = await committedResources()
        var result = ResourceValidator.validate(
            configuration.startRequest.resources,
            host: host,
            committed: committed
        )

        var missing: [String] = []
        func require(_ url: URL?, _ label: String) {
            guard let url else { return }
            if !FileManager.default.isReadableFile(atPath: url.path) {
                missing.append("\(label): \(url.path)")
            }
        }
        require(configuration.startRequest.kernelURL, "kernel")
        require(configuration.startRequest.initialRamdiskURL, "initial ramdisk")
        for disk in configuration.startRequest.disks { require(disk.url, "disk image") }

        // The ADB port becomes a real host forward inside the backend, so it
        // has to be checked alongside the configured ones or two devices can
        // claim it and the second fails as an opaque QEMU bind error.
        if let adb = configuration.startRequest.adbHostPort, committed.hostPorts.contains(adb) {
            result.errors.append(.invalidConfiguration(
                field: "ADB port",
                detail: """
                    Host port \(adb) is already forwarded by another running device. \
                    Stop that device, or give this one a different ADB port.
                    """
            ))
        }

        for problem in configuration.startRequest.network.problems(
            claimedHostPorts: committed.hostPorts
        ) {
            result.errors.append(.invalidConfiguration(field: "Networking", detail: problem))
        }

        if !missing.isEmpty {
            result.errors.append(.invalidConfiguration(
                field: "Guest images",
                detail: "Not found or not readable — \(missing.joined(separator: "; "))"
            ))
        }
        return result
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard !state.isActive else {
            throw MultiemuError.invalidConfiguration(
                field: "Session state",
                detail: "\(configuration.deviceName) is already \(state.displayName.lowercased())."
            )
        }

        // Move out of the idle state before the first `await`. The guard above
        // reads `state`, and preflight suspends the actor — so without this two
        // concurrent `start()` calls both pass the guard and spawn a backend
        // each, orphaning one of them.
        apply(state: .starting)

        let checks = await preflight()
        for warning in checks.warnings {
            eventContinuation.yield(.preflightWarning(warning))
        }
        guard checks.isAllowed else {
            let failure = GuestFailure(
                kind: .resourcePreflightFailed,
                summary: "The device cannot start on this Mac right now.",
                detail: checks.errors.map(\.remediation).joined(separator: "\n")
            )
            apply(state: .failed(failure))
            throw checks.errors.first ?? MultiemuError.invalidConfiguration(
                field: "Preflight", detail: failure.detail
            )
        }

        // A new run clears the previous failure only once we have actually
        // decided to start. Until then the last failure stays visible.
        lastFailure = nil
        lastBootTimeline = []
        runCount += 1
        runStartedAt = ContinuousClock().now

        let newBackend = backendFactory()
        backend = newBackend
        supervise(newBackend)

        do {
            try await newBackend.start(configuration.startRequest)
        } catch {
            // The backend published `.failed` on its event stream, but that
            // delivery is asynchronous: a caller that catches this error and
            // immediately reads `state` would otherwise see a stale `.starting`.
            // Read the backend's state directly and apply it before throwing.
            // Safe against reordering because `.failed` is terminal — the event
            // stream cannot later deliver a newer state that this would undo.
            apply(state: await newBackend.state)
            throw error
        }
    }

    public func requestShutdown(timeout: Duration = .seconds(20)) async {
        guard let backend else { return }
        await backend.requestShutdown(timeout: timeout)
    }

    public func terminate() async {
        guard let backend else { return }
        await backend.terminate()
    }

    /// Starts again after a failure or a clean stop, reusing the configuration.
    public func restart() async throws {
        if state.isActive {
            await requestShutdown()
        }
        supervision?.cancel()
        supervision = nil
        backend = nil
        apply(state: .inactive)
        try await start()
    }

    public func updateConfiguration(_ newConfiguration: Configuration) throws {
        guard !state.isActive else {
            throw MultiemuError.invalidConfiguration(
                field: "Session state",
                detail: "Stop \(configuration.deviceName) before changing its configuration."
            )
        }
        configuration = newConfiguration
    }

    // MARK: - Supervision

    private func supervise(_ newBackend: any EmulatorBackend) {
        let stream = newBackend.events
        // A previous run's supervisor is not guaranteed to have ended — the
        // backend does not finish its event stream — so replacing the task
        // without cancelling would leave it consuming a dead backend's events.
        supervision?.cancel()
        supervision = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: BackendEvent) async {
        switch event {
        case .stateChanged(let newState):
            apply(state: newState)
        case .bootMilestone(let milestone):
            lastBootTimeline.append(milestone)
            if milestone.kind.isTerminalSuccess, let runStartedAt {
                lastBootDuration = ContinuousClock().now - runStartedAt
            }
            eventContinuation.yield(.bootMilestone(milestone))
        case .consoleLine(let line):
            eventContinuation.yield(.consoleLine(line))
        case .backendMessage(let message):
            eventContinuation.yield(.notice("backend: \(message)"))
        case .backendNotification(let name, let detail):
            eventContinuation.yield(.notice(detail.isEmpty ? name : "\(name): \(detail)"))
        }
    }

    private func apply(state newState: GuestRunState) {
        guard newState != state else { return }
        state = newState
        if let failure = newState.failure {
            // Retained deliberately: the backend process is about to disappear
            // and this is the only remaining record of why.
            lastFailure = failure
            MultiemuLog.lifecycle.error("""
                \(self.configuration.deviceName, privacy: .public) failed: \
                \(failure.kind.rawValue, privacy: .public) — \(failure.summary, privacy: .public)
                """)
        }
        eventContinuation.yield(.stateChanged(newState))
    }

    /// The live backend, for engine-specific diagnostics only.
    ///
    /// Nothing in the application may drive a guest through this — lifecycle
    /// goes through the session. It exists so tools can ask an engine questions
    /// the abstraction deliberately does not model, such as QMP status.
    public func currentBackendForDiagnostics() -> (any EmulatorBackend)? { backend }

    // MARK: - Diagnostics

    /// Human-readable state that survives the backend, for the diagnostics
    /// bundle and for the eventual UI.
    public func diagnosticsSummary() -> String {
        var lines: [String] = []
        lines.append("Device        \(configuration.deviceName)")
        lines.append("State         \(state.displayName)")
        lines.append("Runs          \(runCount)")
        lines.append("Guest         \(configuration.startRequest.guestArchitecture.displayName), \(configuration.startRequest.acceleration.displayName)")
        lines.append("Resources     \(configuration.startRequest.resources.vcpuCount) vCPU, \(ByteCount.describe(configuration.startRequest.resources.memoryBytes))")
        if let lastBootDuration {
            lines.append("Last boot     \(String(format: "%.3f s", lastBootDuration.seconds))")
        }
        if !lastBootTimeline.isEmpty {
            lines.append("Timeline      " + lastBootTimeline
                .map { String(format: "%@@%.3fs", $0.kind.rawValue, $0.elapsed.seconds) }
                .joined(separator: ", "))
        }
        if let lastFailure {
            lines.append("Last failure  [\(lastFailure.kind.rawValue)] \(lastFailure.summary)")
            lines.append("              \(lastFailure.detail.replacingOccurrences(of: "\n", with: "\n              "))")
            if let code = lastFailure.backendExitCode {
                lines.append("              backend exit code \(code)")
            }
            if !lastFailure.consoleTail.isEmpty {
                lines.append("              last console lines:")
                for line in lastFailure.consoleTail.suffix(5) {
                    lines.append("                \(line)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
