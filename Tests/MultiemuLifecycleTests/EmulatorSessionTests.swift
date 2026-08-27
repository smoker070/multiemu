import Foundation
import MultiemuBackend
import MultiemuHost
import MultiemuSupport
import Testing
@testable import MultiemuLifecycle

/// A controllable stand-in for a real engine.
///
/// Lets the coordinator's policy — preflight, state mirroring, failure
/// retention, restart — be tested without a hypervisor, which means these tests
/// run on any Mac and in CI.
actor MockBackend: EmulatorBackend {

    enum Behaviour: Sendable {
        case bootsSuccessfully
        case failsToLaunch
        case panicsDuringBoot
    }

    static var descriptor: BackendDescriptor {
        BackendCatalogue.descriptor(for: .qemuHardwareAccelerated)
    }

    private var currentState: GuestRunState = .inactive
    private let behaviour: Behaviour
    var state: GuestRunState { currentState }

    nonisolated let events: AsyncStream<BackendEvent>
    private nonisolated let continuation: AsyncStream<BackendEvent>.Continuation

    init(behaviour: Behaviour) {
        self.behaviour = behaviour
        var captured: AsyncStream<BackendEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { captured = $0 }
        self.continuation = captured
    }

    private func transition(to newState: GuestRunState) {
        currentState = newState
        continuation.yield(.stateChanged(newState))
    }

    func start(_ request: GuestStartRequest) async throws {
        transition(to: .starting)
        switch behaviour {
        case .failsToLaunch:
            let failure = GuestFailure(
                kind: .backendLaunchFailed,
                summary: "The emulator backend could not be started.",
                detail: "mock: launch refused"
            )
            transition(to: .failed(failure))
            throw MultiemuError.backendUnavailable(backend: "mock", reason: "launch refused")

        case .panicsDuringBoot:
            transition(to: .booting(lastMilestone: nil))
            let milestone = BootMilestone(kind: .kernelPanic, matchedLine: "Kernel panic - not syncing", elapsed: .seconds(2))
            continuation.yield(.bootMilestone(milestone))
            transition(to: .failed(.init(
                kind: .guestPanicked,
                summary: "The guest kernel failed to start.",
                detail: milestone.matchedLine,
                consoleTail: ["Kernel panic - not syncing"],
                lastBootMilestone: .kernelPanic
            )))

        case .bootsSuccessfully:
            transition(to: .booting(lastMilestone: nil))
            for kind in [BootMilestone.Kind.kernelStarted, .initStarted, .userspaceReady] {
                continuation.yield(.bootMilestone(.init(kind: kind, matchedLine: kind.rawValue, elapsed: .milliseconds(100))))
            }
            transition(to: .running)
        }
    }

    /// Simulates the backend process dying without being asked to.
    func simulateUnexpectedDeath() {
        transition(to: .failed(.init(
            kind: .backendTerminatedUnexpectedly,
            summary: "The emulator backend stopped unexpectedly.",
            detail: "mock: killed",
            backendExitCode: 9,
            consoleTail: ["line one", "line two"],
            lastBootMilestone: .userspaceReady
        )))
    }

    func requestShutdown(timeout: Duration) async { transition(to: .inactive) }
    func terminate() async { transition(to: .inactive) }
    func recentConsole(limit: Int) -> [String] { [] }
}

/// Captures the most recently created mock so a test can drive it.
final class BackendBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: MockBackend?
    private(set) var creationCount = 0

    func store(_ backend: MockBackend) {
        lock.lock(); defer { lock.unlock() }
        storage = backend
        creationCount += 1
    }

    var current: MockBackend? {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

@Suite("Emulator session")
struct EmulatorSessionTests {

    private func temporaryFile() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("multiemu-test-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: Data("kernel".utf8))
        return url
    }

    private func makeSession(
        behaviour: MockBackend.Behaviour = .bootsSuccessfully,
        host: HostCapabilities = .makeFixture(),
        memoryBytes: UInt64 = 4 * ByteCount.giB,
        kernel: URL?,
        box: BackendBox = BackendBox()
    ) -> (EmulatorSession, BackendBox) {
        let request = GuestStartRequest(
            guestArchitecture: .arm64,
            acceleration: .hardwareVirtualization,
            resources: .init(memoryBytes: memoryBytes, storageBytes: 32 * ByteCount.giB, vcpuCount: 4),
            kernelURL: kernel,
            bootTimeout: .seconds(5)
        )
        let session = EmulatorSession(
            configuration: .init(deviceName: "Test device", startRequest: request),
            host: host,
            backendFactory: {
                let backend = MockBackend(behaviour: behaviour)
                box.store(backend)
                return backend
            }
        )
        return (session, box)
    }

    /// Polls until `predicate` holds, so tests do not depend on event timing.
    private func wait(
        for session: EmulatorSession,
        timeout: Duration = .seconds(2),
        until predicate: @Sendable @escaping (GuestRunState) -> Bool
    ) async -> GuestRunState {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let state = await session.state
            if predicate(state) { return state }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await session.state
    }

    // MARK: Preflight

    @Test("Preflight refuses a guest larger than the host allows, and nothing starts")
    func preflightRefusesOversizedGuest() async {
        let (session, box) = makeSession(
            host: .makeFixture(physicalMemoryBytes: 8 * ByteCount.giB),
            memoryBytes: 8 * ByteCount.giB,
            kernel: temporaryFile()
        )
        await #expect(throws: (any Error).self) { try await session.start() }

        let state = await session.state
        #expect(state.failure?.kind == .resourcePreflightFailed)
        // The decisive part: no backend was ever created.
        #expect(box.creationCount == 0)
    }

    @Test("Preflight detects a missing kernel image before anything is launched")
    func preflightDetectsMissingImage() async {
        // Milestone 2 established that engine-level validation cannot be relied
        // on for this: VZVirtualMachineConfiguration.validate() accepts a kernel
        // URL that does not exist. The coordinator must catch it itself.
        let (session, box) = makeSession(
            kernel: URL(fileURLWithPath: "/definitely/not/here/vmlinuz")
        )
        let checks = await session.preflight()
        #expect(!checks.isAllowed)
        #expect(checks.errors.contains { $0.remediation.contains("vmlinuz") })

        await #expect(throws: (any Error).self) { try await session.start() }
        #expect(box.creationCount == 0)
    }

    @Test("Preflight warnings are surfaced but do not block a start")
    func preflightWarningsDoNotBlock() async {
        let (session, _) = makeSession(
            host: .makeFixture(physicalMemoryBytes: 16 * ByteCount.giB,
                               estimatedAvailableMemoryBytes: 1 * ByteCount.giB),
            kernel: temporaryFile()
        )
        let checks = await session.preflight()
        #expect(checks.isAllowed)
        #expect(!checks.warnings.isEmpty)
        try? await session.start()
        #expect(await wait(for: session) { $0 == .running } == .running)
    }

    // MARK: Normal lifecycle

    @Test("A successful start mirrors backend state through to running")
    func successfulStart() async throws {
        let (session, box) = makeSession(kernel: temporaryFile())
        try await session.start()
        #expect(await wait(for: session) { $0 == .running } == .running)
        #expect(box.creationCount == 1)
        #expect(await session.runCount == 1)
        #expect(await session.lastBootDuration != nil)
        #expect(await session.lastBootTimeline.count == 3)
    }

    @Test("Configuration cannot be changed while a guest is active")
    func configurationIsLockedWhileActive() async throws {
        let (session, _) = makeSession(kernel: temporaryFile())
        try await session.start()
        _ = await wait(for: session) { $0 == .running }

        let replacement = EmulatorSession.Configuration(
            deviceName: "Renamed",
            startRequest: await session.configuration.startRequest
        )
        await #expect(throws: MultiemuError.self) { try await session.updateConfiguration(replacement) }
        #expect(await session.configuration.deviceName == "Test device")
    }

    // MARK: Failure handling

    @Test("A launch failure is recorded as failed state with a reason")
    func launchFailure() async {
        let (session, _) = makeSession(behaviour: .failsToLaunch, kernel: temporaryFile())
        await #expect(throws: (any Error).self) { try await session.start() }
        let failure = await session.state.failure
        #expect(failure?.kind == .backendLaunchFailed)
        #expect(await session.lastFailure?.kind == .backendLaunchFailed)
    }

    @Test("A guest panic is recorded with its console tail")
    func guestPanic() async throws {
        let (session, _) = makeSession(behaviour: .panicsDuringBoot, kernel: temporaryFile())
        try await session.start()
        let state = await wait(for: session) { $0.failure != nil }
        #expect(state.failure?.kind == .guestPanicked)
        #expect(state.failure?.lastBootMilestone == .kernelPanic)
        #expect(state.failure?.consoleTail.isEmpty == false)
    }

    @Test("Control state survives the backend dying unexpectedly")
    func controlStateSurvivesBackendDeath() async throws {
        // This is the Milestone 3 acceptance criterion, in unit-test form.
        let (session, box) = makeSession(kernel: temporaryFile())
        try await session.start()
        _ = await wait(for: session) { $0 == .running }

        await box.current?.simulateUnexpectedDeath()
        let state = await wait(for: session) { $0.failure != nil }

        #expect(state.failure?.kind == .backendTerminatedUnexpectedly)
        #expect(state.failure?.backendExitCode == 9)

        // Everything the application needs is still here after the engine is gone.
        #expect(await session.configuration.deviceName == "Test device")
        #expect(await session.runCount == 1)
        #expect(await session.lastBootTimeline.count == 3)
        #expect(await session.lastFailure?.consoleTail.count == 2)

        let summary = await session.diagnosticsSummary()
        #expect(summary.contains("Test device"))
        #expect(summary.contains("backendTerminatedUnexpectedly"))
        #expect(summary.contains("backend exit code 9"))
    }

    @Test("A failed session restarts, with a fresh backend and a bumped run count")
    func restartAfterFailure() async throws {
        let (session, box) = makeSession(kernel: temporaryFile())
        try await session.start()
        _ = await wait(for: session) { $0 == .running }
        await box.current?.simulateUnexpectedDeath()
        _ = await wait(for: session) { $0.failure != nil }

        try await session.restart()
        #expect(await wait(for: session) { $0 == .running } == .running)
        #expect(box.creationCount == 2)
        #expect(await session.runCount == 2)
        // The previous failure is cleared once a new run actually begins.
        #expect(await session.lastFailure == nil)
    }

    @Test("Starting twice is refused rather than spawning a second backend")
    func doubleStartRefused() async throws {
        let (session, box) = makeSession(kernel: temporaryFile())
        try await session.start()
        _ = await wait(for: session) { $0 == .running }
        await #expect(throws: MultiemuError.self) { try await session.start() }
        #expect(box.creationCount == 1)
    }

    // MARK: State model

    @Test("A backend without snapshot support says so rather than pretending")
    func snapshotsDefaultToUnsupported() async throws {
        // The protocol carries default implementations so a backend that cannot
        // snapshot reports it, instead of silently doing nothing.
        let backend = MockBackend(behaviour: .bootsSuccessfully)
        await #expect(throws: MultiemuError.self) { try await backend.captureSnapshot(tag: "x") }
        await #expect(throws: MultiemuError.self) { try await backend.restoreSnapshot(tag: "x") }
        await #expect(throws: MultiemuError.self) { try await backend.deleteSnapshot(tag: "x") }
        #expect(try await backend.listSnapshots().isEmpty)
    }

    @Test("Active states are exactly those with a live backend")
    func activeStateClassification() {
        #expect(!GuestRunState.inactive.isActive)
        #expect(GuestRunState.starting.isActive)
        #expect(GuestRunState.booting(lastMilestone: nil).isActive)
        #expect(GuestRunState.running.isActive)
        #expect(GuestRunState.stopping.isActive)
        #expect(!GuestRunState.failed(.init(kind: .bootTimedOut, summary: "s", detail: "d")).isActive)
    }
}
