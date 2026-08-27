import Darwin
import Foundation
import MultiemuADB
import MultiemuBackend
import MultiemuConfiguration
import MultiemuDBus
import MultiemuGraphics
import MultiemuImages
import MultiemuInput
import MultiemuLifecycle
import MultiemuQEMU
import MultiemuRecording
import MultiemuSupport
import Observation

/// One line in a device's activity log.
public struct ActivityEntry: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable {
        case state, boot, notice, console, error
    }

    public let id = UUID()
    public var kind: Kind
    public var text: String
    public var timestamp: Date

    public init(kind: Kind, text: String, timestamp: Date = Date()) {
        self.kind = kind
        self.text = text
        self.timestamp = timestamp
    }
}

/// A single virtual device, as the interface sees it.
///
/// This is the boundary layer: it is the only place that knows about sessions,
/// backends and D-Bus. Views bind to the properties here and never import a
/// backend module, so replacing the backend cannot reach the interface.
@MainActor
@Observable
public final class DeviceModel: Identifiable {

    public let id: UUID
    public private(set) var profile: VirtualDeviceProfile
    public private(set) var state: GuestRunState = .inactive
    public private(set) var latestFrame: GuestFrame?
    public private(set) var activity: [ActivityEntry] = []
    public private(set) var snapshots: [SnapshotHandle] = []
    public private(set) var framesPresented = 0
    public private(set) var lastBootDuration: Duration?
    /// Set when an action fails in a way the user should see.
    public var lastError: String?

    /// How the guest image is fitted into the display area.
    public var scaling: GuestDisplayScaling = .aspectFit

    private let store: VirtualDeviceStore
    private let imageStore: ImageStore
    /// What sibling devices have already claimed, excluding this one.
    ///
    /// Synchronous and main-actor bound on purpose: admission has to read this
    /// and take the claim without suspending in between, or two devices
    /// starting together both pass.
    private let committedResources: @MainActor @Sendable (UUID) -> CommittedResources
    private let helpers: HelperLocator
    private let host: HostCapabilitiesSnapshot
    private var session: EmulatorSession?
    private var display: QEMUDisplayClient?
    private var input: QEMUInputClient?
    private var router: InputRouter?
    private var recording: RecordingSession?
    /// Bumped by every attach and every detach.
    ///
    /// `attachDisplay` suspends several times; without this it can resume after
    /// a `detachDisplay` that ran in between and rebuild a router and a gamepad
    /// monitor for a guest that is already gone.
    private var attachGeneration = 0
    /// Watches for a game controller. Started with the display and stopped with
    /// it, so a stopped device does not keep listening.
    private let gamepad = GamepadMonitor()
    /// Observers of the session's own lifecycle. These must outlive the
    /// display: detaching a display must not stop the sidebar from learning
    /// that the guest shut down.
    private var sessionTasks: [Task<Void, Never>] = []
    /// Observers of the frame stream, torn down whenever the display detaches.
    private var displayTasks: [Task<Void, Never>] = []

    /// Most recent lines kept; older ones are discarded so a long-running guest
    /// cannot grow the log without bound.
    private static let activityLimit = 500

    public init(
        profile: VirtualDeviceProfile,
        store: VirtualDeviceStore,
        imageStore: ImageStore,
        helpers: HelperLocator,
        host: HostCapabilitiesSnapshot,
        committedResources: @escaping @MainActor @Sendable (UUID) -> CommittedResources = { _ in .none }
    ) {
        self.committedResources = committedResources
        self.imageStore = imageStore
        self.id = profile.id
        self.profile = profile
        self.store = store
        self.helpers = helpers
        self.host = host
    }

    // MARK: - Derived presentation state

    public var name: String { profile.name }
    public var isRunning: Bool { state.isActive }
    public var canStart: Bool { !state.isActive }
    public var canStop: Bool { state.isActive }
    public var canSnapshot: Bool { if case .running = state { return true } else { return false } }
    public var statusText: String { state.displayName }

    public var resourceSummary: String {
        "\(profile.vcpuCount) vCPU · \(ByteCount.describe(profile.memoryBytes)) · \(ByteCount.describe(profile.storageBytes))"
    }

    public var displaySummary: String {
        "\(profile.display.widthInPixels) × \(profile.display.heightInPixels) · \(profile.display.densityDPI) dpi"
    }

    // MARK: - Lifecycle

    public func start() async {
        guard canStart else { return }
        lastError = nil

        // Admission and the claim are ONE step, taken here without suspending.
        //
        // Checking and claiming separately does not work in either order.
        // Claiming first makes every device weigh itself against its siblings'
        // claims and, when several start together, they all refuse each other.
        // Checking first leaves a window in which two devices each read a total
        // that excludes the other and both are admitted. Doing both between two
        // suspension points on the main actor is what makes it correct: nothing
        // else runs in between.
        let admission = ResourceValidator.validate(
            profile.resources, host: host.capabilities, committed: committedResources(id))
        for warning in admission.warnings { append(.notice, warning) }
        guard admission.isAllowed else {
            lastError = admission.errors.map(\.remediation).joined(separator: "\n")
            append(.error, lastError ?? "")
            return
        }
        state = .starting

        let emulator = helpers.locateEmulator(for: profile.guestArchitecture)
        guard let executable = emulator.url else {
            lastError = """
                No emulator backend was found for \(profile.guestArchitecture.displayName). \
                Searched: \(emulator.searchedPaths.joined(separator: ", ")).
                """
            append(.error, lastError ?? "")
            // Release the claim taken above; nothing was started.
            state = .inactive
            return
        }
        append(.notice, "Backend: \(executable.path) (\(emulator.source.rawValue))")

        let displayMode = GuestDisplayMode.attached(
            widthInPixels: profile.display.widthInPixels,
            heightInPixels: profile.display.heightInPixels,
            // Allocated square and large enough for every preset, so the
            // resolution can be changed and the display rotated without
            // restarting the guest.
            framebufferSide: DisplayProfile.runtimeFramebufferSide
        )

        let request: GuestStartRequest
        do {
            request = try makeStartRequest(displayMode: displayMode)
        } catch {
            lastError = (error as? MultiemuError)?.remediation ?? String(describing: error)
            append(.error, lastError ?? "")
            state = .inactive
            return
        }

        let identifier = id
        let committed = committedResources
        let newSession = EmulatorSession(
            configuration: .init(deviceName: profile.name, startRequest: request),
            host: host.capabilities,
            // The session re-checks on its own behalf, which also covers a
            // restart. It excludes this device for the same reason admission
            // above does: by now the claim is already taken.
            committedResources: { await MainActor.run { committed(identifier) } },
            backendFactory: { QEMUBackend(executableURL: executable) }
        )
        session = newSession
        observe(newSession)

        do {
            try await newSession.start()
            await attachDisplay(to: newSession)
        } catch {
            lastError = (error as? MultiemuError)?.remediation ?? String(describing: error)
            append(.error, lastError ?? "")
            // Adopt the session's own verdict rather than leaving the optimistic
            // `.starting` in place. A device refused by preflight never started,
            // so it must fall back to inactive and stop counting as committed —
            // otherwise one refusal would permanently shrink the host budget.
            state = await newSession.state
        }
    }

    public func stop() async {
        guard let session else { return }
        append(.notice, "Shutting down")
        await session.requestShutdown()
        await detachDisplay()
    }

    public func forceStop() async {
        guard let session else { return }
        append(.notice, "Forcing termination")
        await session.terminate()
        await detachDisplay()
    }

    public func restart() async {
        guard let session else { await start(); return }
        await detachDisplay()
        do {
            try await session.restart()
            // Deliberately NOT re-observing. The session and its event stream
            // both survive a restart, and the existing observer is still on it.
            // Re-registering would cancel that observer first, and cancelling an
            // AsyncStream's consumer *finishes the stream* — verified — so the
            // replacement would receive nothing and this device's state would
            // freeze for the rest of its life. The observer survives because
            // `detachDisplay` no longer cancels session tasks.
            await attachDisplay(to: session)
        } catch {
            lastError = String(describing: error)
            append(.error, lastError ?? "")
        }
    }

    /// Turns this device's configured image into something the backend can boot.
    ///
    /// The image decides the shape of the request — kernel, ramdisk, command
    /// line and which partitions are attached — so the plan is built from the
    /// installed image set rather than assembled here. Without an installed
    /// image there is nothing to boot, and saying so plainly is better than
    /// starting a guest with no kernel and letting it fail as a boot timeout
    /// three minutes later.
    private func makeStartRequest(displayMode: GuestDisplayMode) throws -> GuestStartRequest {
        let acceleration: AccelerationMode =
            host.hardwareVirtualizationAvailable ? .hardwareVirtualization : .softwareTranslation

        guard let manifest = try? imageStore.manifest(for: profile.imageIdentifier) else {
            throw MultiemuError.invalidConfiguration(
                field: "System image",
                detail: """
                    No image called "\(profile.imageIdentifier)" is installed. Install one with \
                    `multiemu-image install`, or choose a different image for this device.
                    """)
        }
        guard let disks = helpers.diskManager() else {
            throw MultiemuError.toolMissing(
                tool: "qemu-img",
                purpose: "preparing this device's private disks",
                installHint: "Development only: `brew install qemu`.")
        }

        // Everything this device writes goes into its own directory; the image
        // store is shared between devices and stays read-only.
        let plan = AndroidGuestPlan(
            manifest: manifest,
            store: imageStore,
            userdataSizeBytes: profile.storageBytes,
            privateStorage: DevicePrivateStorage(
                directory: store.directory(for: id), disks: disks))

        var request = try plan.makeStartRequest(
            resources: profile.resources,
            acceleration: acceleration)
        request.displayMode = displayMode
        request.network = profile.network
        request.audio = profile.audioMode
        return request
    }

    // MARK: - Display

    /// Applies a display profile to the running guest and remembers it.
    ///
    /// The guest decides its own resolution; this asks. Whether it complied is
    /// visible in the next scanout, which is also what re-scales the input
    /// mapping — so a mode the guest refuses leaves both the picture and the
    /// mapping consistent with reality rather than with the request.
    public func applyDisplayProfile(_ display: DisplayProfile) async {
        var updated = profile
        updated.display = display
        update(updated)

        guard let input else {
            append(.notice, "Display set to \(display.widthInPixels)×\(display.heightInPixels); it applies at next start")
            return
        }
        do {
            try await input.setUIInfo(
                width: UInt32(display.widthInPixels), height: UInt32(display.heightInPixels))
            append(.notice, "Requested \(display.widthInPixels)×\(display.heightInPixels) at \(display.densityDPI) dpi")
        } catch {
            lastError = String(describing: error)
            append(.error, "Could not change the display mode: \(error)")
        }
    }

    /// Turns the guest display a quarter turn.
    public func rotateDisplay() async {
        await applyDisplayProfile(profile.display.rotated())
    }

    // MARK: - Recording

    /// Starts recording the guest display to the user's Movies folder.
    ///
    /// The output size is fixed at the guest's current resolution: a video file
    /// cannot change dimensions, and the guest may rotate or resize while
    /// recording. Later frames of a different size are fitted into it.
    public func startRecording(framesPerSecond: Int = 30) {
        guard recording == nil else { return }
        guard let frame = latestFrame else {
            lastError = "There is nothing to record until the guest has drawn a frame."
            append(.error, lastError ?? "")
            return
        }

        let directory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = directory
            .appendingPathComponent("Multiemu", isDirectory: true)
            .appendingPathComponent("\(profile.name) \(stamp).mov")

        let session = RecordingSession(configuration: .init(
            url: url, width: frame.width, height: frame.height,
            framesPerSecond: framesPerSecond))
        do {
            // Seeded with what is on screen now: the recorder is fed by new
            // frames, and a still guest sends none.
            try session.start(initialFrame: frame)
            recording = session
            recordingURL = url
            append(.notice, "Recording \(frame.width)×\(frame.height) at \(framesPerSecond) fps")
        } catch {
            lastError = String(describing: error)
            append(.error, "Could not start recording: \(error)")
        }
    }

    public func stopRecording() async {
        guard let session = recording else { return }
        recording = nil
        recordingURL = nil
        do {
            let summary = try await session.stop()
            append(.notice, """
                Recorded \(summary.framesWritten) frames \
                (\(summary.width)×\(summary.height) at \(summary.framesPerSecond) fps, \
                \(ByteCount.describe(summary.fileSizeBytes))) to \(summary.url.lastPathComponent)
                """)
            if summary.ticksSkipped > 0 {
                append(.error, """
                    \(summary.ticksSkipped) frames could not be encoded in time, so the \
                    recording runs shorter than real time.
                    """)
            }
        } catch {
            lastError = String(describing: error)
            append(.error, "Could not finish the recording: \(error)")
        }
    }

    // MARK: - Snapshots

    public func refreshSnapshots() async {
        guard let backend = await session?.currentBackendForDiagnostics() else { return }
        snapshots = (try? await backend.listSnapshots()) ?? []
    }

    public func captureSnapshot(named tag: String) async {
        guard let backend = await session?.currentBackendForDiagnostics() else { return }
        do {
            let handle = try await backend.captureSnapshot(tag: tag)
            append(.notice, "Snapshot \"\(handle.tag)\" captured (\(ByteCount.describe(handle.vmStateSizeBytes ?? 0)))")
            await refreshSnapshots()
        } catch {
            lastError = String(describing: error)
            append(.error, "Snapshot failed: \(lastError ?? "")")
        }
    }

    public func restoreSnapshot(_ handle: SnapshotHandle) async {
        guard let backend = await session?.currentBackendForDiagnostics() else { return }
        do {
            try await backend.restoreSnapshot(tag: handle.tag)
            append(.notice, "Restored snapshot \"\(handle.tag)\"")
        } catch {
            lastError = String(describing: error)
            append(.error, "Restore failed: \(lastError ?? "")")
        }
    }

    public func deleteSnapshot(_ handle: SnapshotHandle) async {
        guard let backend = await session?.currentBackendForDiagnostics() else { return }
        try? await backend.deleteSnapshot(tag: handle.tag)
        await refreshSnapshots()
    }

    // MARK: - Device management

    public func factoryReset() async {
        guard !state.isActive else {
            lastError = "Stop the device before resetting it."
            return
        }
        do {
            try store.factoryReset(id)
            append(.notice, "Factory reset complete")
        } catch {
            lastError = String(describing: error)
        }
    }

    public func update(_ newProfile: VirtualDeviceProfile) {
        // `reload()` reconciles by calling this for every device, so an
        // unconditional save rewrote every profile on disk — and bumped every
        // `modifiedAt` — each time any device was created or deleted.
        guard newProfile != profile else { return }
        do {
            profile = try store.save(newProfile)
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Writes the current frame to a PNG at the guest's own resolution.
    public func captureScreenshot(to directory: URL) -> URL? {
        guard let frame = latestFrame else {
            lastError = "There is no frame to capture yet."
            return nil
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("\(profile.name) \(stamp).png")
        do {
            try frame.writePNG(to: url)
            append(.notice, "Screenshot saved to \(url.lastPathComponent)")
            return url
        } catch {
            lastError = String(describing: error)
            return nil
        }
    }

    // MARK: - Packages

    /// The host port forwarded to the guest's adbd, if this device has one.
    ///
    /// Read from the device's own forwards rather than assumed: two devices
    /// running at once must not be handed the same port, which is why
    /// `HostPortAllocator` exists and why this is per-device.
    public var adbHostPort: Int? {
        profile.network.portForwards.first { $0.guestPort == 5555 }?.hostPort
    }

    public var canInstallPackage: Bool { isRunning && adbHostPort != nil }

    /// Installs an APK the user chose, over this device's ADB forward.
    ///
    /// The file is checked before anything is sent — an APK is a ZIP with an
    /// `AndroidManifest.xml`, and a file that is not one is refused here rather
    /// than after a several-hundred-megabyte transfer ending in
    /// `INSTALL_PARSE_FAILED_NOT_APK`. The extension is a claim by whoever
    /// named the file; the contents are the evidence.
    @discardableResult
    public func installPackage(at url: URL) async -> Bool {
        guard isRunning else {
            lastError = "Start the device before installing a package."
            return false
        }
        guard let port = adbHostPort else {
            lastError = "This device has no ADB port forward, so packages cannot be installed."
            return false
        }

        append(.notice, "Installing \(url.lastPathComponent)…")
        let device = ADBDevice(port: port, timeout: 300)

        // On a thread, not in a `Task`: every call in `ADBDevice` blocks, and a
        // blocking call on the cooperative pool holds a thread for its whole
        // duration. A large APK would freeze the interface.
        let result: Result<ADBDevice.InstallResult, Error> = await withCheckedContinuation { continuation in
            let thread = Thread {
                do { continuation.resume(returning: .success(try device.install(apk: url))) }
                catch { continuation.resume(returning: .failure(error)) }
            }
            thread.name = "multiemu.install-package"
            thread.start()
        }

        switch result {
        case let .success(outcome):
            let megabytes = Double(outcome.packageBytes) / 1_048_576
            append(.notice, String(
                format: "Installed %@ (%.1f MB) in %.2f s",
                url.lastPathComponent, megabytes, outcome.totalSeconds))
            return true
        case let .failure(error):
            let detail = String(describing: error)
            lastError = detail
            append(.error, "Could not install \(url.lastPathComponent): \(detail)")
            return false
        }
    }

    // MARK: - Input, forwarded from the display view

    public func inputClient() -> QEMUInputClient? { input }

    /// The active key and gamepad mapping, once a display is attached.
    public func inputRouter() -> InputRouter? { router }

    /// Whether this device is the one a game controller drives.
    ///
    /// `GCExtendedGamepad.valueChangedHandler` is a single slot on one shared
    /// controller object, so with several devices running they would otherwise
    /// take it from each other and input would land on whichever attached last.
    /// Ownership follows the selection instead.
    public private(set) var receivesGamepadInput = false
    /// Whether a recording is running, and where it will be written.
    public private(set) var recordingURL: URL?
    public var isRecording: Bool { recording != nil }

    public func setReceivesGamepadInput(_ receives: Bool) {
        guard receives != receivesGamepadInput else { return }
        receivesGamepadInput = receives
        guard router != nil else { return }
        if receives {
            gamepad.start()
        } else {
            // Lift anything the pad was holding in this guest before handing the
            // controller over, or it keeps a finger down it can never raise.
            router?.apply(.neutral)
            gamepad.stop()
        }
    }

    /// Applies a different mapping and remembers the choice with the device.
    public func selectInputProfile(_ id: UUID) {
        guard profile.activeInputProfileID != id,
              let selected = profile.effectiveInputProfiles.first(where: { $0.id == id })
        else { return }
        var updated = profile
        updated.activeInputProfileID = id
        update(updated)
        router?.setProfile(selected)
        append(.notice, "Input mapping: \(selected.name)")
    }

    /// Saves an edited mapping and applies it immediately.
    public func saveInputProfile(_ inputProfile: InputProfile) {
        var updated = profile
        updated.upsertInputProfile(inputProfile)
        update(updated)
        router?.setProfile(inputProfile)
        for problem in inputProfile.problems() { append(.error, problem) }
    }

    // MARK: - Wiring

    private func observe(_ session: EmulatorSession) {
        sessionTasks.forEach { $0.cancel() }
        sessionTasks.removeAll()
        let events = session.events
        sessionTasks.append(Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .stateChanged(let newState):
                    self.state = newState
                    self.append(.state, newState.displayName)
                    if let failure = newState.failure {
                        self.lastError = failure.summary
                        self.append(.error, failure.detail)
                    }
                    // A guest can stop without anyone asking it to — a panic, a
                    // boot timeout, or the user shutting it down from inside.
                    // Tearing down only from stop()/forceStop() leaks the
                    // display connection and its reader thread on every such
                    // exit, and leaves the last frame on screen under a
                    // "Stopped" label.
                    if !newState.isActive, self.display != nil {
                        await self.detachDisplay()
                    }
                case .bootMilestone(let milestone):
                    self.append(.boot, String(format: "%.3f s  %@", milestone.elapsed.seconds, milestone.kind.rawValue))
                case .consoleLine(let line):
                    self.append(.console, line)
                case .notice(let notice):
                    self.append(.notice, notice)
                case .preflightWarning(let warning):
                    self.append(.notice, warning)
                }
            }
        })
    }

    private func attachDisplay(to session: EmulatorSession) async {
        attachGeneration += 1
        let generation = attachGeneration
        guard let backend = await session.currentBackendForDiagnostics() as? QEMUBackend,
              let control = await backend.controlChannelIfConnected() else {
            append(.error, "The display channel is unavailable; the guest is running without a picture.")
            return
        }

        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { return }
        do {
            try await control.sendFileDescriptor(descriptors[1], named: "displayfd")
            try await control.addClient(protocolName: "@dbus-display", fileDescriptorName: "displayfd")
        } catch {
            Darwin.close(descriptors[0]); Darwin.close(descriptors[1])
            append(.error, "Could not attach the display: \(error)")
            return
        }
        Darwin.close(descriptors[1])

        let connection = DBusConnection(descriptor: descriptors[0], role: .client)
        do { try await connection.authenticate() } catch {
            // The connection owns descriptors[0] and a reader thread from here
            // on; dropping it on the floor leaks both.
            await connection.close()
            append(.error, "Display handshake failed: \(error)")
            return
        }

        let client = QEMUDisplayClient(consoleConnection: connection)
        let stream = client.events
        do { try await client.registerListener() } catch {
            await connection.close()
            append(.error, "Could not register a display listener: \(error)")
            return
        }
        let inputClient = QEMUInputClient(connection: connection)

        // QEMU reports its own touch-slot limit; the mapping must not hand out
        // more than it accepts.
        let slots = await inputClient.maxTouchSlots()

        // The last suspension point is behind us; if a detach happened while we
        // were waiting, this attach is stale and must not install anything.
        guard generation == attachGeneration else {
            await connection.close()
            return
        }
        display = client
        input = inputClient

        // Ask the guest for the mode this device is configured for.
        //
        // Without this the guest keeps the SQUARE boot framebuffer — 1920x1920,
        // allocated that way so rotation can swap the axes — and two things go
        // wrong at once:
        //
        //   * It renders 3.7 million pixels instead of this device's 921,600,
        //     four times the work per frame, over the same D-Bus channel. That
        //     is the "lagging and freezing".
        //   * `InputRouter` below is built with the *profile's* size, so every
        //     pointer position is mapped into a coordinate space the guest is
        //     not using and lands somewhere else entirely. That is the "nothing
        //     happens when I click".
        //
        // The performance harness always did this by hand and its comment said
        // "the emulator does both" — it did not. Only the resolution picker and
        // rotation ever called it, so a device that was simply started ran at
        // the boot allocation for its whole life.
        do {
            try await inputClient.setUIInfo(
                width: UInt32(profile.display.widthInPixels),
                height: UInt32(profile.display.heightInPixels))
            append(.notice, "Display mode requested: "
                + "\(profile.display.widthInPixels)×\(profile.display.heightInPixels)")
        } catch {
            append(.error, "Could not set the display mode; the guest keeps its boot "
                + "framebuffer and will be slow and mis-aimed: \(error)")
        }

        let mapping = profile.activeInputProfile ?? .starter
        let newRouter = InputRouter(
            profile: mapping,
            guestSize: CGSize(width: profile.display.widthInPixels,
                              height: profile.display.heightInPixels),
            client: inputClient,
            maximumSlots: slots > 0 ? slots : 10
        )
        newRouter.onDiagnostics = { [weak self] problems in
            for problem in problems { self?.append(.error, problem) }
        }
        router = newRouter
        gamepad.onChange = { [weak newRouter] snapshot in newRouter?.apply(snapshot) }
        gamepad.onAvailabilityChange = { [weak self] name in
            self?.append(.notice, name.map { "Game controller connected: \($0)" }
                ?? "Game controller disconnected")
        }
        if receivesGamepadInput { gamepad.start() }

        append(.notice, "Display attached · mapping \"\(mapping.name)\" · \(slots) touch slots")

        displayTasks.append(Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                if case .scanout(let frame) = event {
                    self.latestFrame = frame
                    self.framesPresented += 1
                    // The guest decides its own resolution, and it need not match
                    // the configured mode. Left pinned to the configured size,
                    // every mapped touch lands at the wrong pixel — while the
                    // pointer, which uses the real framebuffer size, lands
                    // correctly. The two input paths must agree.
                    self.router?.setGuestSize(
                        CGSize(width: frame.width, height: frame.height))
                    // Cheap by design: this stores the frame and returns. The
                    // encode happens on the recorder's own cadence, so a
                    // recording cannot slow the interactive display.
                    self.recording?.submit(frame)
                }
            }
        })
    }

    private func detachDisplay() async {
        attachGeneration += 1
        // Finish the file rather than abandon it: an unfinalised mov is
        // unplayable, so stopping the guest must not lose the recording.
        if recording != nil { await stopRecording() }
        // Lift anything the mapping is holding before the channel goes away,
        // otherwise the guest is left with fingers down.
        router?.releaseAll()
        router?.shutdown()
        gamepad.stop()
        gamepad.onChange = nil
        gamepad.onAvailabilityChange = nil
        router = nil
        await display?.close()
        display = nil
        input = nil
        latestFrame = nil
        displayTasks.forEach { $0.cancel() }
        displayTasks.removeAll()
    }

    /// Stops observing the session. Separate from `detachDisplay` so that a
    /// restart, which detaches and re-attaches the display, keeps reporting
    /// state throughout.
    private func stopObserving() {
        sessionTasks.forEach { $0.cancel() }
        sessionTasks.removeAll()
    }

    private func append(_ kind: ActivityEntry.Kind, _ text: String) {
        guard !text.isEmpty else { return }
        activity.append(ActivityEntry(kind: kind, text: text))
        if activity.count > Self.activityLimit {
            activity.removeFirst(activity.count - Self.activityLimit)
        }
    }
}
