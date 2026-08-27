import Darwin
import Foundation
import MultiemuSupport

/// A QEMU Machine Protocol client over a UNIX domain socket.
///
/// QMP without out-of-band commands is strictly ordered request/response on one
/// connection, so pending commands are matched to replies with a FIFO queue.
/// Asynchronous events can arrive at any point, interleaved with replies, and
/// are routed to `events` instead.
///
/// Lines are read on a dedicated thread rather than the cooperative pool,
/// because the read is blocking and must not occupy a pool thread for the life
/// of the VM. Order is preserved by funnelling every line through one
/// `AsyncStream` consumed by a single task.
public actor QMPClient {

    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        /// `sockaddr_un.sun_path` is 104 bytes on Darwin. This is a real limit
        /// that ordinary-looking project paths exceed.
        case socketPathTooLong(path: String, limit: Int)
        case socketCreationFailed(errnoValue: Int32)
        case connectTimedOut(path: String, waited: Duration)
        case notConnected
        case handshakeFailed(String)
        case commandFailed(errorClass: String, description: String)
        case connectionClosed
        case jobTimedOut(command: String, jobID: String)

        public var description: String {
            switch self {
            case let .socketPathTooLong(path, limit):
                return "The control socket path is \(path.utf8.count) bytes; macOS allows at most \(limit - 1). Path: \(path)"
            case let .socketCreationFailed(errnoValue):
                return "Could not create a UNIX socket: \(String(cString: strerror(errnoValue)))"
            case let .connectTimedOut(path, waited):
                return "QEMU did not accept a control connection at \(path) within \(waited.seconds) s."
            case .notConnected:
                return "The QMP control channel is not connected."
            case let .handshakeFailed(reason):
                return "QMP handshake failed: \(reason)"
            case let .commandFailed(errorClass, description):
                return "QEMU rejected the command (\(errorClass)): \(description)"
            case .connectionClosed:
                return "The QMP control channel closed."
            case let .jobTimedOut(command, jobID):
                return "The \(command) job \(jobID) did not conclude within the timeout."
            }
        }
    }

    /// Darwin's `sockaddr_un.sun_path` capacity.
    public static let socketPathLimit = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    /// Builds a control socket path short enough for `sockaddr_un`.
    ///
    /// Project directories routinely exceed 104 bytes, so control sockets never
    /// live beside the virtual device. They go in the system temporary
    /// directory under a short random name and are removed on teardown.
    public static func makeSocketPath(role: String) -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("mm-\(role)-\(suffix).sock")
        return base
    }

    private var descriptor: Int32 = -1
    private var pendingReplies: [CheckedContinuation<JSONValue, any Error>] = []
    private var readerTask: Task<Void, Never>?
    private var isConnected = false

    private let eventContinuation: AsyncStream<QMPProtocol.Event>.Continuation
    public nonisolated let events: AsyncStream<QMPProtocol.Event>

    public private(set) var greeting: QMPProtocol.Greeting?

    public init() {
        var capturedContinuation: AsyncStream<QMPProtocol.Event>.Continuation!
        self.events = AsyncStream { capturedContinuation = $0 }
        self.eventContinuation = capturedContinuation
    }

    // MARK: - Connection

    /// Connects, reads the greeting, and completes capability negotiation.
    ///
    /// QEMU creates its socket asynchronously during startup, so a connection
    /// refused early is normal and is retried until `timeout`.
    @discardableResult
    public func connect(
        toSocketAt path: String,
        timeout: Duration = .seconds(15),
        retryInterval: Duration = .milliseconds(25)
    ) async throws -> QMPProtocol.Greeting {
        guard path.utf8.count < Self.socketPathLimit else {
            throw Failure.socketPathTooLong(path: path, limit: Self.socketPathLimit)
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while true {
            if let descriptor = try openSocket(path: path) {
                self.descriptor = descriptor
                break
            }
            guard clock.now < deadline else {
                throw Failure.connectTimedOut(path: path, waited: timeout)
            }
            try? await Task.sleep(for: retryInterval)
        }

        let lines = startReader(descriptor: descriptor)
        isConnected = true

        // The greeting must arrive before anything else.
        var iterator = lines.makeAsyncIterator()
        guard let greetingLine = await iterator.next() else {
            throw Failure.handshakeFailed("QEMU closed the socket before sending a greeting.")
        }
        guard case .greeting(let greeting) = try QMPProtocol.decode(line: greetingLine) else {
            throw Failure.handshakeFailed("Expected a QMP greeting, got: \(greetingLine.prefix(200))")
        }
        self.greeting = greeting

        // Everything after the greeting is dispatched by the consumer task.
        readerTask = Task { [weak self] in
            while let line = await iterator.next() {
                await self?.receive(line: line)
            }
            await self?.handleConnectionClosed()
        }

        // QMP rejects every command until capabilities are negotiated.
        _ = try await execute("qmp_capabilities")

        MultiemuLog.backend.info("QMP connected: QEMU \(greeting.qemuVersion, privacy: .public)")
        return greeting
    }

    private func openSocket(path: String) throws -> Int32? {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw Failure.socketCreationFailed(errnoValue: errno)
        }

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
        return nil  // Not yet listening; the caller retries.
    }

    /// Reads lines on a dedicated thread and funnels them through one stream,
    /// which is what guarantees FIFO reply matching.
    private nonisolated func startReader(descriptor: Int32) -> AsyncStream<String> {
        AsyncStream { continuation in
            let thread = Thread {
                var buffer = [UInt8](repeating: 0, count: 8192)
                var pending = Data()
                while true {
                    let count = read(descriptor, &buffer, buffer.count)
                    guard count > 0 else { break }
                    pending.append(contentsOf: buffer[0..<count])
                    while let newlineIndex = pending.firstIndex(of: 0x0A) {
                        let lineData = pending[pending.startIndex..<newlineIndex]
                        pending.removeSubrange(pending.startIndex...newlineIndex)
                        continuation.yield(String(decoding: lineData, as: UTF8.self))
                    }
                }
                continuation.finish()
            }
            thread.name = "com.multiemu.qmp.reader"
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    // MARK: - Dispatch

    private func receive(line: String) {
        let message: QMPProtocol.Message
        do {
            message = try QMPProtocol.decode(line: line)
        } catch {
            // A line we cannot parse is a protocol fault worth recording, but it
            // must not desynchronise reply matching or kill the connection.
            MultiemuLog.backend.error("Undecodable QMP line: \(line.prefix(200), privacy: .public)")
            return
        }

        switch message {
        case .event(let event):
            eventContinuation.yield(event)
        case .success(let value):
            resumeNextPending(with: .success(value))
        case .failure(let errorClass, let description):
            resumeNextPending(with: .failure(Failure.commandFailed(errorClass: errorClass, description: description)))
        case .greeting:
            // A second greeting means QEMU restarted the channel underneath us.
            MultiemuLog.backend.error("Unexpected second QMP greeting; treating the channel as reset.")
        }
    }

    private func resumeNextPending(with result: Result<JSONValue, any Error>) {
        guard !pendingReplies.isEmpty else {
            MultiemuLog.backend.error("QMP reply with no pending command — reply matching may be out of sync.")
            return
        }
        pendingReplies.removeFirst().resume(with: result)
    }

    private func handleConnectionClosed() {
        isConnected = false
        let waiting = pendingReplies
        pendingReplies.removeAll()
        for continuation in waiting {
            continuation.resume(throwing: Failure.connectionClosed)
        }
        eventContinuation.finish()
    }

    // MARK: - Commands

    @discardableResult
    public func execute(
        _ command: String,
        arguments: [String: JSONValue] = [:]
    ) async throws -> JSONValue {
        guard isConnected, descriptor >= 0 else { throw Failure.notConnected }

        let payload = try QMPProtocol.encode(command: command, arguments: arguments)

        return try await withCheckedThrowingContinuation { continuation in
            // Write first, enqueue second. `receive` is actor-isolated and this
            // closure runs synchronously inside the actor, so no reply can be
            // dispatched between the two steps — which means a failed write
            // never leaves an unmatched slot to desynchronise later replies.
            let written = payload.withUnsafeBytes { bytes -> Int in
                write(descriptor, bytes.baseAddress, bytes.count)
            }
            guard written == payload.count else {
                continuation.resume(throwing: Failure.connectionClosed)
                return
            }
            pendingReplies.append(continuation)
        }
    }

    /// Hands a file descriptor to QEMU and registers it under `name`.
    ///
    /// Used to attach an out-of-process display client: a socket pair is
    /// created, one end is passed here, and `addClient` then tells QEMU to speak
    /// the display protocol over it. QEMU takes the descriptor from the
    /// ancillary data of the `getfd` message itself, so the command and the
    /// descriptor travel together.
    @discardableResult
    public func sendFileDescriptor(_ descriptor: Int32, named name: String) async throws -> JSONValue {
        guard isConnected, self.descriptor >= 0 else { throw Failure.notConnected }
        let payload = try QMPProtocol.encode(command: "getfd", arguments: ["fdname": .string(name)])

        return try await withCheckedThrowingContinuation { continuation in
            // Same ordering rule as `execute`: write first, enqueue second.
            do {
                try QMPFileDescriptorTransfer.send(
                    descriptor: descriptor, with: payload, over: self.descriptor
                )
            } catch {
                continuation.resume(throwing: error)
                return
            }
            pendingReplies.append(continuation)
        }
    }

    /// Attaches a previously passed descriptor to a QEMU client protocol.
    ///
    /// `protocol` values that matter here: `@dbus-display` for the D-Bus
    /// peer-to-peer display channel, `vnc` for a VNC client socket.
    public func addClient(protocolName: String, fileDescriptorName: String) async throws {
        try await execute("add_client", arguments: [
            "protocol": .string(protocolName),
            "fdname": .string(fileDescriptorName),
        ])
    }

    /// `query-display-options` — reports the active display backend.
    public func queryDisplayOptions() async throws -> JSONValue {
        try await execute("query-display-options")
    }

    /// Runs a QMP **job** and waits for it to conclude.
    ///
    /// Snapshot commands do not complete synchronously: they create a job and
    /// return immediately, so success has to be read from `query-jobs`. A job
    /// that concluded with an `error` field is a failure even though the
    /// original command returned success — treating the command's reply as the
    /// outcome would report every failed snapshot as having worked.
    ///
    /// Concluded jobs stay in the list until dismissed, so `job-dismiss` is
    /// mandatory rather than tidy-up: without it the next job of the same name
    /// collides with the corpse of the last one.
    @discardableResult
    public func runJob(
        _ command: String,
        jobID: String,
        arguments: [String: JSONValue],
        timeout: Duration = .seconds(120),
        pollInterval: Duration = .milliseconds(100)
    ) async throws -> JSONValue {
        var payload = arguments
        payload["job-id"] = .string(jobID)
        try await execute(command, arguments: payload)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            let jobs = try await execute("query-jobs")
            guard case .array(let entries) = jobs else { break }
            guard let job = entries.first(where: { $0["id"]?.stringValue == jobID }) else {
                // The job vanished before we saw it conclude. Treat that as
                // success only if it was never reported failing, which it
                // cannot have been if it is gone without an error.
                return .null
            }
            let status = job["status"]?.stringValue ?? "unknown"
            if let failure = job["error"]?.stringValue {
                _ = try? await execute("job-dismiss", arguments: ["id": .string(jobID)])
                throw Failure.commandFailed(errorClass: "JobFailed", description: failure)
            }
            if status == "concluded" {
                _ = try? await execute("job-dismiss", arguments: ["id": .string(jobID)])
                return job
            }
            if status == "null" || status == "aborting" {
                _ = try? await execute("job-dismiss", arguments: ["id": .string(jobID)])
                throw Failure.commandFailed(errorClass: "JobFailed", description: "job ended in status \(status)")
            }
            try? await Task.sleep(for: pollInterval)
        }
        throw Failure.jobTimedOut(command: command, jobID: jobID)
    }

    /// `query-status` — the canonical liveness check.
    public func queryStatus() async throws -> String {
        let result = try await execute("query-status")
        return result["status"]?.stringValue ?? "unknown"
    }

    /// Asks the guest to power down via ACPI. The guest may ignore it.
    public func requestGuestPowerdown() async throws {
        try await execute("system_powerdown")
    }

    /// Tells QEMU itself to exit. Clean, but does not ask the guest.
    public func quit() async throws {
        // `quit` may close the socket before a reply is written, which is not
        // an error — it is the command succeeding.
        do {
            try await execute("quit")
        } catch Failure.connectionClosed {
            return
        }
    }

    public func disconnect() {
        readerTask?.cancel()
        readerTask = nil
        isConnected = false
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        handleConnectionClosed()
    }
}
