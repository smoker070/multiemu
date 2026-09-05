import Darwin
import Foundation
import MultiemuBackend
import MultiemuGuestServices
import MultiemuDisks
import MultiemuSupport

/// The QEMU implementation of `EmulatorBackend`.
///
/// Owns exactly three things and nothing else: a child process, a QMP control
/// channel, and the boot state machine. Policy — whether starting is allowed,
/// what to do after a failure — belongs to the lifecycle coordinator, not here.
public actor QEMUBackend: EmulatorBackend {

    public static var descriptor: BackendDescriptor {
        // Identifies the engine. The acceleration mode actually in use comes
        // from the start request, because one QEMU binary provides both.
        BackendCatalogue.descriptor(for: .qemuHardwareAccelerated)
    }

    /// How many console lines to retain for diagnostics. A guest that dies at
    /// boot is diagnosed almost entirely from these.
    public static let consoleRetentionLimit = 400

    private let executableURL: URL
    private var process: QEMUProcess?
    private var controlChannel: QMPClient?
    private var controlSocketPath: String?

    private var bootProbe = GuestBootProbe()
    private var console: [String] = []
    private var backendMessages: [String] = []

    private var currentState: GuestRunState = .inactive
    /// Distinguishes "we asked it to stop" from "it died", which is the whole
    /// difference between a clean shutdown and a crash report.
    private var stopWasRequested = false
    /// The disk whose `backend-run.json` this backend owns, remembered so every
    /// exit path can clear it — `handleExit` never sees the start request.
    private var runRecordDisk: URL?
    private var launchedAt: ContinuousClock.Instant?
    private var supervisionTasks: [Task<Void, Never>] = []
    /// Block nodes a snapshot may address: writable qcow2 only. Read-only and
    /// raw nodes cannot hold machine state, and asking them to produces an
    /// error that reads like a QEMU bug rather than a configuration mistake.
    private var snapshotNodeNames: [String] = []
    private var snapshotImageURL: URL?
    private var bootWatchdog: Task<Void, Never>?

    public nonisolated let events: AsyncStream<BackendEvent>
    private nonisolated let eventContinuation: AsyncStream<BackendEvent>.Continuation

    public var state: GuestRunState { currentState }

    /// The helper process this backend supervises, when one is running.
    ///
    /// Exposed for diagnostics: with several devices running it is the simplest
    /// evidence that each really has its own process rather than sharing one.
    public var processIdentifier: Int32? { process?.processIdentifier }

    public init(executableURL: URL) {
        self.executableURL = executableURL
        var captured: AsyncStream<BackendEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(2048)) { captured = $0 }
        self.eventContinuation = captured
    }

    /// Resolves the QEMU executable for a guest architecture.
    ///
    /// Development convenience only. Shipping builds pass an explicit URL inside
    /// `Multiemu.app/Contents/Helpers/`.
    public static func locateDevelopmentExecutable(for architecture: GuestArchitecture) -> URL? {
        let name = QEMUConfiguration.executableName(for: architecture)
        for directory in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    // MARK: - Lifecycle

    /// Host-side answers for console ports that need one, live for the run.
    private var consoleResponders: [GuestConsoleResponder] = []
    /// Port socket paths, kept so they can be unlinked when the run ends.
    private var consoleSocketPathsInUse: [String] = []
    /// The console port carrying Android's shell, when one was configured.
    /// Held so the quiesce below can reach it once the guest has booted.
    private var androidConsoleSocketPath: String?
    /// Set once the quiesce has run, so a guest that reports boot completion
    /// more than once is not repeatedly reconfigured.
    private var hasQuiescedGuestServices = false

    /// Which guest console port each responder serves, so a stalled boot can
    /// name the port rather than leaving the user with a bare timeout.
    private var consolePortsInUse: [(index: Int, service: String, responder: GuestConsoleResponder)] = []
    /// How many console ports the run asked for, so a failure can distinguish
    /// "a port stopped answering" from "nothing was ever going to answer".
    private var requestedConsolePortCount = 0

    public func start(_ request: GuestStartRequest) async throws {
        guard !currentState.isActive else {
            throw MultiemuError.invalidConfiguration(
                field: "Backend state",
                detail: "A guest is already \(currentState.displayName.lowercased())."
            )
        }

        // A restart clears the previous run entirely. Carrying a stale boot
        // probe or console across runs produces reports that blame the wrong run.
        await stopConsoleResponders()
        bootProbe = GuestBootProbe()
        console.removeAll()
        backendMessages.removeAll()
        stopWasRequested = false

        transition(to: .starting)

        let socketPath = QMPClient.makeSocketPath(role: "qmp")
        controlSocketPath = socketPath

        requestedConsolePortCount = request.consolePorts.count
        // A port that something must answer on needs a socket QEMU listens on;
        // the rest can be silent. Paths are allocated here so the same values
        // reach both the command line and the responders started below.
        let consoleSocketPaths: [Int: String] = request.consolePorts.enumerated()
            .reduce(into: [:]) { paths, entry in
                guard entry.element.service != .silent else { return }
                paths[entry.offset] = QMPClient.makeSocketPath(role: "hvc\(entry.offset)")
            }

        let configuration = makeConfiguration(
            request, controlSocketPath: socketPath, consoleSocketPaths: consoleSocketPaths)
        let arguments: [String]
        do {
            arguments = try QEMUCommandBuilder.arguments(for: configuration)
        } catch {
            fail(.init(
                kind: .backendLaunchFailed,
                summary: "The backend command line is invalid.",
                detail: String(describing: error)
            ))
            throw error
        }

        MultiemuLog.backend.info("Launching: \((try? QEMUCommandBuilder.displayCommandLine(for: configuration)) ?? "?", privacy: .public)")

        let qemu = QEMUProcess(executableURL: executableURL, arguments: arguments)
        process = qemu
        launchedAt = ContinuousClock().now

        do {
            try qemu.start()
        } catch {
            fail(.init(
                kind: .backendLaunchFailed,
                summary: "The emulator backend could not be started.",
                detail: String(describing: error)
            ))
            throw error
        }

        // A note naming this process, so a launch after a crash can recognise
        // its own leftover backend instead of leaving it to hold the disk. See
        // `BackendRunRecord`. Written after the launch succeeds, because a
        // process that never started has nothing to reclaim.
        runRecordDisk = request.disks.first(where: { !$0.isReadOnly })?.url
        if let disk = runRecordDisk,
           let live = BackendRunRecord.liveProcess(qemu.processIdentifier) {
            BackendRunRecord.write(
                .init(
                    processIdentifier: qemu.processIdentifier,
                    startedAtSeconds: live.seconds,
                    startedAtMicroseconds: live.microseconds,
                    executablePath: executableURL.path,
                    processName: live.name
                ),
                besideDisk: disk
            )
        }

        // Started after QEMU, because they connect to sockets it listens on.
        // A guest whose sensors HAL goes unanswered never reaches
        // sys.boot_completed, so a failure here is reported rather than
        // swallowed — but it is not fatal to the launch itself.
        for (index, port) in request.consolePorts.enumerated() {
            guard let path = consoleSocketPaths[index] else { continue }
            let service: any QemudService
            switch port.service {
            case .silent: continue
            case .androidConsole:
                // Not a protocol the host answers — a shell the host drives,
                // and only after the guest has booted. Remember where it is.
                androidConsoleSocketPath = path
                consoleSocketPathsInUse.append(path)
                continue
            case .sensors: service = SensorsService()
            }
            let index = index
            let name = port.service.rawValue
            let responder = GuestConsoleResponder(socketPath: path, service: service) { [weak self] health in
                guard health != .serving else { return }
                Task { await self?.noteConsoleHealth(port: index, service: name, health: health) }
            }
            do {
                try await responder.start()
                consoleResponders.append(responder)
                consoleSocketPathsInUse.append(path)
                consolePortsInUse.append((index: index, service: name, responder: responder))
            } catch {
                MultiemuLog.backend.error(
                    "Could not serve /dev/hvc\(index, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        transition(to: .booting(lastMilestone: nil))
        superviseProcess(qemu)
        startBootWatchdog(timeout: request.bootTimeout)

        // The control channel is desirable but not fatal: a guest that boots
        // without QMP is still a booted guest, and reporting "backend failed"
        // for a control-plane problem would be a lie.
        await connectControlChannel(at: socketPath)
    }

    /// Ends the host-side console services. Called on every path out of a run,
    /// so a stopped device leaves no reader threads behind.
    /// Records a responder that has stopped being able to answer.
    ///
    /// Routed through the ordinary backend-message channel so it reaches the
    /// event stream and the failure detail, rather than only the log.
    private func noteConsoleHealth(
        port: Int, service: String, health: GuestConsoleResponder.Health
    ) {
        switch health {
        case .serving:
            return
        case let .couldNotConnect(path):
            // A dead backend is the reason nothing connected, not a second
            // problem to report. Without this guard the failure detail carries
            // a sentence about a sensors HAL for a QEMU that never opened its
            // disk image, sending the reader after a guest that never existed.
            guard process?.isRunning == true, currentState.failure == nil else {
                MultiemuLog.backend.debug(
                    "Console port \(port, privacy: .public) did not connect, but the backend is already gone")
                return
            }
            handleBackendMessage(
                "The host could not attach to guest console port \(port) (\(service)) at \(path); "
                + "a HAL waiting on it will block the boot.")
        case let .gaveUp(faults):
            handleBackendMessage(
                "Guest console port \(port) (\(service)) was abandoned after \(faults) protocol faults; "
                + "a HAL waiting on it will block the boot.")
        }
    }

    /// A one-line account of each console port, for a failure report.
    ///
    /// A sensors port that has answered nothing while the guest was booting is
    /// the single most useful fact about a stalled Android boot, and it is not
    /// recoverable from the console log.
    private func consolePortSummary() async -> String? {
        // The empty cases matter more than the populated one. A guest whose
        // sensors port was never wired stalls identically to one whose
        // responder died, and reports the same bare timeout — so say which.
        if consolePortsInUse.isEmpty {
            if requestedConsolePortCount == 0 {
                return "none configured; an Android guest stalls without the ports its HALs expect"
            }
            return "\(requestedConsolePortCount) present but none answering a protocol; "
                + "a HAL waiting on one will block the boot"
        }
        var parts: [String] = []
        for entry in consolePortsInUse {
            let serving = await entry.responder.isServing
            let replies = await entry.responder.repliesSent
            let faults = await entry.responder.faultsSeen
            parts.append(
                "hvc\(entry.index)/\(entry.service): "
                + (serving ? "serving" : "NOT SERVING")
                + ", \(replies) replies, \(faults) faults")
        }
        return parts.joined(separator: "; ")
    }

    /// Stops guest services this host cannot support, once the guest is up.
    ///
    /// Runs on its own thread because `GuestServiceQuiesce.perform` blocks on
    /// socket reads for several seconds. Looping a blocking call on the
    /// cooperative pool has already cost this project a measurement harness
    /// that starved its own executor and died without writing a report.
    ///
    /// Failure is reported, never fatal. A guest that keeps two services
    /// crash-looping is wasteful, not broken, and refusing to run over it
    /// would turn a performance problem into an availability one.
    private func quiesceUnsupportedGuestServices() {
        guard !hasQuiescedGuestServices, let path = androidConsoleSocketPath else { return }
        hasQuiescedGuestServices = true
        let shell = GuestConsoleShell(socketPath: path)
        let thread = Thread { [weak self] in
            let message: String
            do {
                let outcome = try shell.withSession { GuestServiceQuiesce.perform(over: $0) }
                message = "Guest services: \(outcome.summary)."
            } catch {
                message = "Guest services were left as they are: \(error)"
            }
            Task { await self?.handleBackendMessage(message) }
        }
        thread.name = "multiemu.guest-quiesce"
        thread.start()
    }

    private func stopConsoleResponders() async {
        for responder in consoleResponders {
            await responder.stop()
        }
        consoleResponders.removeAll()
        consolePortsInUse.removeAll()
        requestedConsolePortCount = 0
        androidConsoleSocketPath = nil
        hasQuiescedGuestServices = false
        // QEMU created these; nothing else removes them, and a device started
        // repeatedly would otherwise leave one file per port per run.
        for path in consoleSocketPathsInUse {
            try? FileManager.default.removeItem(atPath: path)
        }
        consoleSocketPathsInUse.removeAll()
    }

    public func requestShutdown(timeout: Duration = .seconds(20)) async {
        guard currentState.isActive else { return }
        stopWasRequested = true
        transition(to: .stopping)
        bootWatchdog?.cancel()
        await stopConsoleResponders()

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        // Escalation ladder, gentlest first. Each rung is given time to work
        // before the next is used, because a guest killed mid-write corrupts
        // its own userdata.
        if let control = controlChannel {
            try? await control.requestGuestPowerdown()
            if await waitForExit(until: clock.now.advanced(by: timeout / 2)) { return }
            try? await control.quit()
            if await waitForExit(until: deadline) { return }
        }

        process?.requestTermination()
        if await waitForExit(until: deadline.advanced(by: .seconds(5))) { return }

        MultiemuLog.backend.error("Backend ignored every graceful stop; sending SIGKILL.")
        process?.kill()
        _ = await waitForExit(until: clock.now.advanced(by: .seconds(5)))
    }

    public func terminate() async {
        guard currentState.isActive else { return }
        stopWasRequested = true
        transition(to: .stopping)
        bootWatchdog?.cancel()
        await stopConsoleResponders()
        process?.kill()
        _ = await waitForExit(until: ContinuousClock().now.advanced(by: .seconds(5)))
    }

    public func recentConsole(limit: Int = 50) -> [String] {
        Array(console.suffix(limit))
    }

    /// The QMP channel, for callers that need engine-specific control
    /// (snapshots, screendump). Returns `nil` when no channel is established.
    public func controlChannelIfConnected() -> QMPClient? { controlChannel }

    // MARK: - Configuration

    private func makeConfiguration(
        _ request: GuestStartRequest,
        controlSocketPath: String,
        consoleSocketPaths: [Int: String]
    ) -> QEMUConfiguration {
        // Drive order is stable and the format is whatever the caller declared;
        // it is never inferred from the file, because QEMU's own documentation
        // treats format probing as a security hazard.
        let drives = request.disks.enumerated().map { index, disk in
            QEMUConfiguration.Drive(
                id: "disk\(index)",
                url: disk.url,
                format: disk.format == .qcow2 ? .qcow2 : .raw,
                readOnly: disk.isReadOnly
            )
        }

        var forwards = request.network.portForwards.map {
            QEMUConfiguration.PortForward(hostPort: $0.hostPort, guestPort: $0.guestPort)
        }
        if let adbHostPort = request.adbHostPort,
           !forwards.contains(where: { $0.hostPort == adbHostPort }) {
            // 5555 is the guest-side ADB port. The host side binds loopback only.
            forwards.append(.init(hostPort: adbHostPort, guestPort: 5555))
        }

        // Record which nodes snapshots may address, before the guest starts.
        let snapshotCapable = drives.filter { $0.format == .qcow2 && !$0.readOnly }
        snapshotNodeNames = snapshotCapable.map(\.nodeName)
        snapshotImageURL = snapshotCapable.first?.url

        return QEMUConfiguration(
            executableURL: executableURL,
            guestArchitecture: request.guestArchitecture,
            acceleration: request.acceleration,
            vcpuCount: request.resources.vcpuCount,
            memoryBytes: request.resources.memoryBytes,
            kernelURL: request.kernelURL,
            initialRamdiskURL: request.initialRamdiskURL,
            kernelCommandLine: request.kernelCommandLine,
            drives: drives,
            portForwards: forwards,
            includeNetworkDevice: request.network.mode != .disabled,
            sharedFolders: request.sharedFolders,
            display: {
                switch request.displayMode {
                case .headless: return .none
                case .attached:
                    // `xres`/`yres` are the BOOT ALLOCATION, not the mode the
                    // user sees: QEMU builds its EDID from them and the guest
                    // will not pick a mode larger than that, per axis, however
                    // many resizes are requested afterwards. A square is
                    // allocated so rotation can swap the axes, and the intended
                    // mode is applied over D-Bus once the display is attached.
                    //
                    // p2p, because plain `dbus` needs a session bus that macOS
                    // does not provide.
                    let side = request.displayMode.bootFramebufferSide ?? 1920
                    return .dbusDisplay(peerToPeer: true, widthInPixels: side, heightInPixels: side)
                }
            }(),
            audio: QEMUConfiguration.audio(for: request.audio),
            includeInputDevices: request.displayMode != .headless,
            serial: .stdio,
            // Index is the guest's /dev/hvcN number, so this order is a
            // contract, not a detail. A port with a responder gets a socket
            // QEMU listens on; the rest only have to exist.
            consolePorts: request.consolePorts.enumerated().map { index, _ in
                if let path = consoleSocketPaths[index] {
                    return .init(backend: .unixSocket(path: path))
                }
                return .init(backend: .null)
            },
            qmpSocketPath: controlSocketPath
        )
    }

    // MARK: - Supervision

    private func superviseProcess(_ qemu: QEMUProcess) {
        // Capture the event stream, not the process. `QEMUProcess` owns a
        // `Process` and is not `Sendable`; the stream is, so only it crosses
        // into the supervising task.
        let stream = qemu.events
        let task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .consoleLine(let line):
                    await self.handleConsole(line: line)
                case .backendMessage(let message):
                    await self.handleBackendMessage(message)
                case .exited(let code, let reason):
                    await self.handleExit(code: code, reason: reason)
                }
            }
        }
        supervisionTasks.append(task)
    }

    private func handleConsole(line: String) {
        console.append(line)
        if console.count > Self.consoleRetentionLimit {
            console.removeFirst(console.count - Self.consoleRetentionLimit)
        }
        eventContinuation.yield(.consoleLine(line))

        guard let launchedAt else { return }
        let elapsed = ContinuousClock().now - launchedAt
        guard let milestone = bootProbe.consume(line: line, elapsed: elapsed) else { return }

        eventContinuation.yield(.bootMilestone(milestone))

        if milestone.kind.isTerminalFailure {
            bootWatchdog?.cancel()
            fail(.init(
                kind: .guestPanicked,
                summary: "The guest kernel failed to start.",
                detail: milestone.matchedLine,
                consoleTail: recentConsole(limit: 40),
                lastBootMilestone: milestone.kind
            ))
            process?.requestTermination()
        } else if milestone.kind.isTerminalSuccess {
            bootWatchdog?.cancel()
            transition(to: .running)
            quiesceUnsupportedGuestServices()
        } else if case .booting = currentState {
            transition(to: .booting(lastMilestone: milestone.kind))
        }
    }

    private func handleBackendMessage(_ message: String) {
        backendMessages.append(message)
        eventContinuation.yield(.backendMessage(message))
    }

    private func handleExit(code: Int32, reason: String) async {
        // The backend is gone, so its run record must not outlive it: a stale
        // record naming a recycled pid is exactly what the identity checks in
        // `BackendRunRecord` exist to refuse, and leaving one behind would make
        // every later launch do that work for nothing.
        if let disk = runRecordDisk { BackendRunRecord.clear(besideDisk: disk) }
        bootWatchdog?.cancel()
        await controlChannel?.disconnect()
        removeControlSocket()
        // A guest that powers itself off, or a QEMU that dies, reaches here and
        // not `requestShutdown`. Without this the responders outlive the run.
        await stopConsoleResponders()

        if stopWasRequested {
            transition(to: .inactive)
            return
        }
        if currentState.failure != nil {
            // Already failed for a more specific reason (a panic); the exit is
            // a consequence of that, not a separate failure.
            return
        }

        // A QEMU that dies during its own startup and a guest that panics after
        // five minutes are different failures and deserve different sentences.
        // The state is flipped to `.booting` before supervision even begins, so
        // it cannot be used to tell them apart; whether anything was ever heard
        // from the guest can.
        let guestEverRan = !console.isEmpty || !bootProbe.milestones.isEmpty

        // `.first`, not `.suffix`. QEMU prints its diagnosis first and the
        // consequences after, so keeping the newest lines is exactly backwards:
        // a backend that printed two warnings before its fatal error would have
        // had the fatal error evicted from its own failure report.
        var lines: [String] = [
            guestEverRan
                ? "The backend process ended by \(reason) with code \(code) while the guest was "
                    + "\(currentState.displayName.lowercased())."
                : "The emulator process ended by \(reason) with code \(code) before the guest began "
                    + "running, so nothing about the Android image is implicated."
        ]
        if let cause = backendMessages.first {
            lines.append("Cause: \(cause)")
            // The one failure common enough to be worth recognising by name:
            // a leftover backend from a session that did not shut down cleanly.
            if cause.contains("Failed to get \"write\" lock") {
                lines.append(
                    "Another process still holds this device's disk. It is usually a Multiemu "
                    + "backend left behind by an earlier session; quitting it releases the disk.")
            }
        }
        let rest = backendMessages.dropFirst().prefix(4)
        if !rest.isEmpty { lines.append("Also reported: " + rest.joined(separator: "; ")) }

        fail(.init(
            kind: .backendTerminatedUnexpectedly,
            summary: guestEverRan
                ? "The emulator backend stopped unexpectedly."
                : "The emulator could not start.",
            detail: lines.joined(separator: "\n"),
            backendExitCode: code,
            consoleTail: recentConsole(limit: 40),
            lastBootMilestone: bootProbe.milestones.last?.kind
        ))
    }

    private func startBootWatchdog(timeout: Duration) {
        bootWatchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            await self.bootDeadlineExpired(timeout: timeout)
        }
    }

    private func bootDeadlineExpired(timeout: Duration) async {
        guard case .booting = currentState else { return }
        // An unanswered console port stalls the guest with no other trace, so
        // the ports go in the report whether or not they look healthy.
        let ports = await consolePortSummary()
        fail(.init(
            kind: .bootTimedOut,
            summary: "The guest did not finish booting within \(Int(timeout.seconds)) seconds.",
            detail: "Last recognised milestone: \(bootProbe.milestones.last?.kind.rawValue ?? "none")."
                + (ports.map { " Guest console ports — \($0)." } ?? ""),
            consoleTail: recentConsole(limit: 40),
            lastBootMilestone: bootProbe.milestones.last?.kind
        ))
        stopWasRequested = true
        process?.kill()
    }

    private func waitForExit(until deadline: ContinuousClock.Instant) async -> Bool {
        let clock = ContinuousClock()
        while clock.now < deadline {
            if process?.isRunning != true { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return process?.isRunning != true
    }

    // MARK: - Control channel

    private func connectControlChannel(at path: String) async {
        let client = QMPClient()
        do {
            let greeting = try await client.connect(toSocketAt: path)
            controlChannel = client
            eventContinuation.yield(.backendNotification(
                name: "control-channel-connected",
                detail: "QEMU \(greeting.qemuVersion)"
            ))
            forwardControlEvents(from: client)
        } catch {
            MultiemuLog.backend.error("QMP control channel unavailable: \(String(describing: error), privacy: .public)")
            eventContinuation.yield(.backendNotification(
                name: "control-channel-unavailable",
                detail: String(describing: error)
            ))
        }
    }

    private func forwardControlEvents(from client: QMPClient) {
        let stream = client.events
        let task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handleControlEvent(event)
            }
        }
        supervisionTasks.append(task)
    }

    private func handleControlEvent(_ event: QMPProtocol.Event) {
        eventContinuation.yield(.backendNotification(
            name: event.name,
            detail: event.data?.description ?? ""
        ))

        // GUEST_PANICKED is authoritative in a way console scraping is not.
        if event.name == "GUEST_PANICKED", currentState.failure == nil {
            fail(.init(
                kind: .guestPanicked,
                summary: "The guest panicked.",
                detail: "QEMU reported GUEST_PANICKED.",
                consoleTail: recentConsole(limit: 40),
                lastBootMilestone: bootProbe.milestones.last?.kind
            ))
        }
    }

    private func removeControlSocket() {
        guard let controlSocketPath else { return }
        try? FileManager.default.removeItem(atPath: controlSocketPath)
        self.controlSocketPath = nil
    }

    // MARK: - State

    private func transition(to newState: GuestRunState) {
        guard newState != currentState else { return }
        MultiemuLog.lifecycle.info("Backend state: \(self.currentState.displayName, privacy: .public) -> \(newState.displayName, privacy: .public)")
        currentState = newState
        eventContinuation.yield(.stateChanged(newState))
    }

    private func fail(_ failure: GuestFailure) {
        transition(to: .failed(failure))
    }

    // MARK: - Snapshots

    public var supportsSnapshots: Bool { !snapshotNodeNames.isEmpty }

    private func snapshotTargets() throws -> String {
        guard let vmstate = snapshotNodeNames.first else {
            throw MultiemuError.invalidConfiguration(
                field: "Snapshots",
                detail: "This device has no writable qcow2 disk, so machine state cannot be stored."
            )
        }
        return vmstate
    }

    private func liveControlChannel() throws -> QMPClient {
        guard let controlChannel else {
            throw MultiemuError.backendUnavailable(
                backend: "QEMU",
                reason: "There is no control channel; the guest may not be running."
            )
        }
        return controlChannel
    }

    public func captureSnapshot(tag: String) async throws -> SnapshotHandle {
        let problems = SnapshotHandle.problems(forTag: tag)
        guard problems.isEmpty else {
            throw MultiemuError.invalidConfiguration(field: "Snapshot tag", detail: problems.joined(separator: " "))
        }
        let control = try liveControlChannel()
        let vmstate = try snapshotTargets()

        let clock = ContinuousClock()
        let started = clock.now
        try await control.runJob(
            "snapshot-save",
            jobID: "save-\(UInt32.random(in: 1_000...999_999))",
            arguments: [
                "tag": .string(tag),
                "vmstate": .string(vmstate),
                "devices": .array(snapshotNodeNames.map { .string($0) }),
            ]
        )
        let elapsed = clock.now - started

        // Read the stored state back from the image, so the reported size is
        // what was actually written rather than what we hoped.
        var handle = SnapshotHandle(tag: tag)
        if let url = snapshotImageURL,
           let manager = VirtualDiskManager.locateDevelopmentTool(),
           let stored = try? manager.snapshots(at: url).last(where: { $0.tag == tag }) {
            handle = stored
        }
        MultiemuLog.snapshot.info("""
            Captured \(tag, privacy: .public) in \(elapsed.milliseconds, privacy: .public) ms, \
            state \(ByteCount.describe(handle.vmStateSizeBytes ?? 0), privacy: .public)
            """)
        return handle
    }

    public func restoreSnapshot(tag: String) async throws {
        let control = try liveControlChannel()
        let vmstate = try snapshotTargets()
        try await control.runJob(
            "snapshot-load",
            jobID: "load-\(UInt32.random(in: 1_000...999_999))",
            arguments: [
                "tag": .string(tag),
                "vmstate": .string(vmstate),
                "devices": .array(snapshotNodeNames.map { .string($0) }),
            ]
        )
        MultiemuLog.snapshot.info("Restored \(tag, privacy: .public)")
    }

    public func deleteSnapshot(tag: String) async throws {
        let control = try liveControlChannel()
        _ = try snapshotTargets()
        try await control.runJob(
            "snapshot-delete",
            jobID: "delete-\(UInt32.random(in: 1_000...999_999))",
            arguments: [
                "tag": .string(tag),
                "devices": .array(snapshotNodeNames.map { .string($0) }),
            ]
        )
    }

    public func listSnapshots() async throws -> [SnapshotHandle] {
        guard let url = snapshotImageURL,
              let manager = VirtualDiskManager.locateDevelopmentTool() else { return [] }
        return (try? manager.snapshots(at: url)) ?? []
    }

    /// Boot timeline of the most recent run, for reports.
    public func bootTimeline() -> [BootMilestone] { bootProbe.milestones }
}
