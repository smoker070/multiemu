import Darwin
import Foundation
import MultiemuSupport

/// Owns one connection to a guest console port for its whole life: the
/// descriptor, the blocking reads, the decode, and the replies.
///
/// **One owner is the entire design.** Two earlier versions split this and both
/// were wrong. The first read on the actor, which pinned its executor for the
/// life of the connection. The second moved reads to a thread but left the
/// descriptor owned by the actor and the replies written from it, which
/// produced three separate defects: the actor could still be pinned by a
/// blocking `write` to a guest that never read; a guest could queue unbounded
/// bytes in the `AsyncStream` between the two halves, defeating the decoder's
/// own cap; and the actor closed a descriptor number the thread was still
/// reading, so a recycled number let one connection read another's bytes.
///
/// Here the thread creates nothing it does not own and the actor touches no
/// descriptor. Read, decode and reply happen in sequence on one thread, so
/// nothing queues: the next `read` does not happen until the previous reply is
/// out, which is backpressure by construction rather than by a buffer size.
private final class ConnectionWorker: @unchecked Sendable {

    private let descriptor: Int32
    private let lock = NSLock()
    private var stopRequested = false
    private var isClosed = false
    private var replies = 0

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    var repliesSent: Int {
        lock.lock(); defer { lock.unlock() }
        return replies
    }

    private var shouldStop: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopRequested
    }

    /// Asks the loop to end and wakes it if it is blocked in `read`.
    ///
    /// `shutdown` rather than `close`: the descriptor number stays this
    /// worker's until its own loop closes it. Closing here would free the
    /// number while the thread was still using it, and the process would hand
    /// the same number to the next socket opened — which is exactly how a
    /// previous version had one connection read another's traffic.
    func requestStop() {
        // `shutdown` and the worker's own `close` are both taken under the
        // lock, so this can never act on a number the worker has already
        // released. Without that, a stop arriving in the window between the
        // worker closing and the actor noticing would shut down whatever the
        // process had since been handed that number.
        lock.lock()
        defer { lock.unlock() }
        stopRequested = true
        if !isClosed { shutdown(descriptor, SHUT_RDWR) }
    }

    /// Runs the connection to completion on the calling thread. Returns whether
    /// it ended in a protocol fault rather than an ordinary close.
    func run(service: any QemudService) -> Bool {
        defer {
            lock.lock()
            isClosed = true
            close(descriptor)
            lock.unlock()
        }

        var decoder = QemudDecoder()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while !shouldStop {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }  // A signal, not a close.
            guard count > 0 else { return false }        // Peer closed, or stopped.

            let messages: [QemudFrame.Message]
            do {
                messages = try decoder.ingest(Data(buffer[0..<count]))
            } catch {
                // Once a length is refused the stream offset is unknown, so the
                // connection cannot be trusted to continue. Drop it.
                MultiemuLog.backend.error(
                    "Guest console protocol fault on \(service.name, privacy: .public): \(String(describing: error), privacy: .public)")
                return true
            }

            for message in messages {
                guard let payload = service.reply(to: message) else { continue }
                guard writeAll(QemudFrame.encode(type: message.type, payload: payload)) else {
                    return false                          // Peer went away mid-reply.
                }
                lock.lock(); replies += 1; lock.unlock()
            }
        }
        return false
    }

    /// `write` may accept fewer bytes than offered, and a short write would
    /// desynchronise the guest's framing.
    private func writeAll(_ data: Data) -> Bool {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { pointer -> Int in
                write(descriptor, pointer.baseAddress, pointer.count)
            }
            guard written > 0 else { return false }
            remaining = remaining.dropFirst(written)
        }
        return true
    }
}

/// Serves one `QemudService` on one virtio-console port.
///
/// QEMU listens on the UNIX socket for the port and this connects to it, so the
/// responder is a client even though it answers the guest. It is started after
/// QEMU and stopped with it.
///
/// It is the one component that reads bytes chosen by the guest, and it is
/// scoped accordingly: a socket, a byte decoder and a lookup table, and nothing
/// else on the host.
public actor GuestConsoleResponder {

    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case socketPathTooLong(path: String, limit: Int)
        case connectTimedOut(path: String)

        public var description: String {
            switch self {
            case let .socketPathTooLong(path, limit):
                return "The console socket path is \(path.utf8.count) bytes; macOS allows at most \(limit - 1). Path: \(path)"
            case let .connectTimedOut(path):
                return "QEMU did not accept a console connection at \(path)."
            }
        }
    }

    /// Darwin's `sockaddr_un.sun_path` capacity.
    public static let socketPathLimit = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    /// What a responder reports about itself, so a caller can say something
    /// specific when a guest stalls.
    ///
    /// Without this the only trace of an unanswered port is a line in the log,
    /// and the guest's stall surfaces as a boot timeout naming nothing — which
    /// is the hardest failure this component produces to diagnose.
    public enum Health: Sendable, Equatable {
        /// Connected and answering.
        case serving
        /// QEMU never accepted a connection within the timeout.
        case couldNotConnect(path: String)
        /// The stream desynchronised too many times; the port is abandoned.
        case gaveUp(faults: Int)

        public var isHealthy: Bool { self == .serving }
    }

    public typealias HealthObserver = @Sendable (Health) -> Void

    /// How many protocol faults are tolerated before the port is abandoned.
    ///
    /// A fault means the stream desynchronised, so the connection is dropped
    /// and remade. Retrying forever would turn a guest that emits garbage into
    /// an unbounded reconnect loop; giving up after a few makes it a reported
    /// failure instead.
    public static let faultBudget = 5

    private let socketPath: String
    private let service: any QemudService
    private let onHealthChange: HealthObserver?

    private var worker: ConnectionWorker?
    private var task: Task<Void, Never>?
    private var isRunning = false
    private var closedConnectionReplies = 0
    /// Bumped on every start. A serve loop checks it before continuing, so a
    /// loop belonging to a previous run can never keep going after a newer one
    /// has begun — `isRunning` alone cannot express that, because both runs
    /// share it.
    private var generation = 0

    public private(set) var faultsSeen = 0

    /// Replies sent across every connection this responder has served.
    public var repliesSent: Int {
        closedConnectionReplies + (worker?.repliesSent ?? 0)
    }

    /// Whether the responder is serving or trying to. False once it has been
    /// stopped or has spent its fault budget.
    public var isServing: Bool { isRunning }

    public init(
        socketPath: String,
        service: any QemudService,
        onHealthChange: HealthObserver? = nil
    ) {
        self.socketPath = socketPath
        self.service = service
        self.onHealthChange = onHealthChange
    }

    /// Connects and begins serving.
    ///
    /// Retries the connect because QEMU may not have created the socket yet;
    /// the caller should not have to sequence against QEMU's startup.
    public func start(connectTimeout: Duration = .seconds(30)) async throws {
        // A stop that is still finishing must be allowed to finish first.
        // Clearing `task` before awaiting it — which an earlier version did —
        // let an overlapping start pass this guard, flip `isRunning` back on,
        // and resurrect the serve loop the stop was waiting for: two loops on
        // one responder, a `stop()` that never returned, and a worker orphaned
        // with its descriptor open.
        if let pending = task {
            if isRunning { return }          // Already serving.
            await pending.value              // Let the previous run finish.
            task = nil
        }
        guard socketPath.utf8.count < Self.socketPathLimit else {
            throw Failure.socketPathTooLong(path: socketPath, limit: Self.socketPathLimit)
        }

        // The budget is per run. Leaving it spent meant a responder that had
        // exhausted it stayed dead for the life of the object while `start()`
        // still reported success.
        faultsSeen = 0
        isRunning = true
        generation += 1
        let thisGeneration = generation

        let path = socketPath
        let service = self.service
        task = Task { [weak self] in
            await self?.serve(
                generation: thisGeneration, path: path,
                service: service, connectTimeout: connectTimeout)
        }
    }

    /// Ends the responder and waits for its connection to be closed.
    ///
    /// When this returns, the descriptor really is closed and no thread is
    /// still reading — a caller tearing down a device needs that to be true,
    /// not merely likely. `task` is cleared only after the await, so a second
    /// concurrent stop waits for the same completion instead of being told the
    /// responder is already stopped while its worker is still running.
    public func stop() async {
        isRunning = false
        worker?.requestStop()
        guard let pending = task else { return }
        await pending.value
        // Another start may have already claimed the slot while this awaited.
        if task == pending { task = nil }
    }

    // MARK: - Serving

    private func serve(
        generation: Int, path: String,
        service: any QemudService, connectTimeout: Duration
    ) async {
        defer {
            // Whatever ended this — a stop, a spent fault budget, a socket that
            // never appeared — the responder is no longer serving. Leaving this
            // true made `start()` silently do nothing afterwards.
            //
            // Guarded by generation so a loop that is finishing cannot clear
            // state belonging to a newer run.
            if generation == self.generation {
                isRunning = false
                worker = nil
            }
        }

        // Cancellation is deliberately not a teardown path: nothing cancels
        // this task, and a cancelled task could not interrupt a worker parked
        // in `read` anyway. `stop()` is the only way to end a responder.
        while isRunning, generation == self.generation, faultsSeen < Self.faultBudget {
            guard let fileDescriptor = await connect(path: path, timeout: connectTimeout) else {
                // `connect` returns nil for two unrelated reasons: the deadline
                // expired, or `stop()` cleared `isRunning` while it was waiting.
                // Only the first is a fault. Reporting the second made every
                // early backend exit manufacture a "port never connected"
                // warning during its own teardown, which then appeared beside
                // the real cause as if it were a second, co-equal problem — and
                // it blamed the guest for something the host had done.
                let wasStopped = !isRunning || generation != self.generation
                MultiemuLog.backend.error("""
                    Guest console responder (\(service.name, privacy: .public))                     \(wasStopped ? "stopped before connecting to" : "could not connect to")                     \(path, privacy: .public)
                    """)
                if !wasStopped { onHealthChange?(.couldNotConnect(path: path)) }
                return
            }
            onHealthChange?(.serving)

            let worker = ConnectionWorker(descriptor: fileDescriptor)
            self.worker = worker
            let faulted = await run(worker, service: service)
            // Read the count before dropping the worker, or the replies it sent
            // vanish from the running total.
            closedConnectionReplies += worker.repliesSent
            self.worker = nil

            if faulted { faultsSeen += 1 }
            guard isRunning, generation == self.generation else { return }
            // The guest closing the port is ordinary — it happens on reboot —
            // so reconnect rather than treating it as an error.
            try? await Task.sleep(for: .milliseconds(200))
        }

        if faultsSeen >= Self.faultBudget {
            MultiemuLog.backend.error(
                "Guest console responder (\(service.name, privacy: .public)) gave up after \(Self.faultBudget) protocol faults")
            onHealthChange?(.gaveUp(faults: faultsSeen))
        }
    }

    /// Runs one connection on its own thread and resumes when it is finished.
    private nonisolated func run(_ worker: ConnectionWorker, service: any QemudService) async -> Bool {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: worker.run(service: service))
            }
            thread.name = "com.multiemu.guestconsole"
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    private func connect(path: String, timeout: Duration) async -> Int32? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, isRunning {
            if let fileDescriptor = openSocket(path: path) { return fileDescriptor }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func openSocket(path: String) -> Int32? {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { return nil }

        // Without this, a guest that closes the port with a request still
        // unanswered kills the whole host process: the reply hits a socket with
        // no reader and `write` raises SIGPIPE, which is fatal by default. A
        // guest closing this port is ordinary — it happens on every reboot — so
        // this is a routine event that must not be able to end the emulator.
        var on: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.utf8CString.withUnsafeBytes { source in
                destination.copyMemory(from: source)
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fileDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return fileDescriptor }
        close(fileDescriptor)
        return nil   // QEMU is not listening yet; the caller retries.
    }
}
