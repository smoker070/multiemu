import Darwin
import Foundation
import MultiemuSupport

/// A peer-to-peer D-Bus connection over an already-connected socket.
///
/// Deliberately *peer-to-peer only*: there is no bus daemon, no name
/// registration and no routing. QEMU's display channel works exactly this way,
/// and modelling a bus we never talk to would be dead weight.
///
/// Both roles are supported because the display path needs both: Multiemu is the
/// **client** on the channel it gets from `add_client`, and the **server** on the
/// listener channel QEMU connects back over.
/// Set MULTIEMU_DBUS_TRACE=1 to trace the handshake and message flow on stderr.
let dbusTraceEnabled = ProcessInfo.processInfo.environment["MULTIEMU_DBUS_TRACE"] == "1"

func dbusTrace(_ message: @autoclosure () -> String) {
    guard dbusTraceEnabled else { return }
    FileHandle.standardError.write(Data("    [dbus] \(message())\n".utf8))
}

public actor DBusConnection {

    public enum Role: Sendable {
        /// Initiates: writes the NUL byte and drives SASL.
        case client
        /// Accepts: reads the NUL byte and answers SASL.
        case server
    }

    public enum Failure: Error, Sendable, CustomStringConvertible {
        case authenticationFailed(String)
        case closed
        case callFailed(name: String, message: String)
        case timedOut(member: String)

        public var description: String {
            switch self {
            case let .authenticationFailed(detail): return "D-Bus authentication failed: \(detail)"
            case .closed: return "The D-Bus connection closed."
            case let .callFailed(name, message): return "\(name): \(message)"
            case let .timedOut(member): return "No reply to \(member) within the timeout."
            }
        }
    }

    /// Handles an inbound method call and returns the reply body, or throws to
    /// produce a D-Bus error reply.
    public typealias MethodHandler = @Sendable (DBusMessage) async -> DBusMessage?

    private let descriptor: Int32
    private let role: Role
    private var nextSerial: UInt32 = 1
    private var pendingCalls: [UInt32: CheckedContinuation<DBusMessage, any Error>] = [:]
    private var readerTask: Task<Void, Never>?
    private var handler: MethodHandler?
    private var isOpen = true
    /// Whether the reader thread exists. Once it does, it owns the descriptor's
    /// lifetime — it is the only thing still reading from it.
    private var readerStarted = false
    /// Guards against a double close, which on a recycled descriptor number
    /// would tear down an unrelated connection.
    private var descriptorReleased = false
    /// Descriptors received with inbound messages, in arrival order.
    private var receivedDescriptors: [Int32] = []

    public init(descriptor: Int32, role: Role) {
        self.descriptor = descriptor
        self.role = role
    }

    public func setMethodHandler(_ handler: @escaping MethodHandler) {
        self.handler = handler
    }

    // MARK: - SASL

    /// Performs the SASL handshake for this connection's role.
    ///
    /// The handshake is line-oriented and blocking, so it runs on a dedicated
    /// thread rather than on the actor. Blocking inside an actor occupies a
    /// cooperative-pool thread for the duration, and with several connections
    /// handshaking at once that starves the pool and deadlocks — which is
    /// exactly what happened the first time this was written the obvious way.
    ///
    /// D-Bus opens with a single NUL byte before any SASL text — a legacy of
    /// credential passing on some platforms — and omitting it makes the peer
    /// reject everything that follows.
    public func authenticate() async throws {
        let descriptor = self.descriptor
        let role = self.role
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let thread = Thread {
                do {
                    switch role {
                    case .client: try DBusConnection.performClientHandshake(on: descriptor)
                    case .server: try DBusConnection.performServerHandshake(on: descriptor)
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.name = "com.multiemu.dbus.auth"
            thread.stackSize = 256 * 1024
            thread.start()
        }
        startReader()
    }

    private nonisolated static func writeLine(_ text: String, to descriptor: Int32) throws {
        try UnixSocketMessaging.send(payload: Array(text.utf8), descriptors: [], over: descriptor)
    }

    /// Reads one CRLF-terminated SASL line.
    ///
    /// Read one byte at a time: SASL lines are short, and reading ahead would
    /// consume the first bytes of the binary message stream that follows BEGIN.
    private nonisolated static func readLine(from descriptor: Int32, timeout: TimeInterval = 10) throws -> String {
        var deadline = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
        var accumulated = [UInt8]()
        while true {
            let (bytes, _) = try UnixSocketMessaging.receive(capacity: 1, over: descriptor)
            guard !bytes.isEmpty else { throw Failure.closed }
            accumulated.append(contentsOf: bytes)
            if accumulated.count >= 2, accumulated.suffix(2) == [0x0D, 0x0A] {
                return String(decoding: accumulated.dropLast(2), as: UTF8.self)
            }
            if accumulated.count > 4096 { throw Failure.authenticationFailed("SASL line too long") }
        }
    }

    private nonisolated static func performClientHandshake(on descriptor: Int32) throws {
        let uidHex = String(getuid()).utf8.map { String(format: "%02x", $0) }.joined()
        try writeLine("\u{0}AUTH EXTERNAL \(uidHex)\r\n", to: descriptor)
        let reply = try readLine(from: descriptor)
        dbusTrace("client <- \(reply)")
        guard reply.hasPrefix("OK ") else { throw Failure.authenticationFailed(reply) }
        // Ask for descriptor passing. QEMU answers AGREE_UNIX_FD; a peer without
        // support answers ERROR, which is not fatal.
        try writeLine("NEGOTIATE_UNIX_FD\r\n", to: descriptor)
        let negotiation = try readLine(from: descriptor)
        dbusTrace("client <- \(negotiation)")
        guard negotiation.hasPrefix("AGREE_UNIX_FD") || negotiation.hasPrefix("ERROR") else {
            throw Failure.authenticationFailed(negotiation)
        }
        try writeLine("BEGIN\r\n", to: descriptor)
    }

    private nonisolated static func performServerHandshake(on descriptor: Int32) throws {
        let (leading, _) = try UnixSocketMessaging.receive(capacity: 1, over: descriptor)
        dbusTrace("server <- NUL (peer connected)")
        guard leading.first == 0 else {
            throw Failure.authenticationFailed("expected a leading NUL byte, got \(leading)")
        }
        while true {
            let line = try readLine(from: descriptor)
            dbusTrace("server <- \(line)")
            if line.hasPrefix("AUTH") {
                // EXTERNAL only. The kernel guarantees the peer's identity on a
                // UNIX socket, and this is a socket pair we created ourselves.
                let guid = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
                try writeLine("OK \(guid)\r\n", to: descriptor)
            } else if line.hasPrefix("NEGOTIATE_UNIX_FD") {
                try writeLine("AGREE_UNIX_FD\r\n", to: descriptor)
            } else if line.hasPrefix("BEGIN") {
                return
            } else if line.hasPrefix("CANCEL") || line.hasPrefix("ERROR") {
                throw Failure.authenticationFailed(line)
            }
        }
    }

    // MARK: - Message loop

    private func startReader() {
        readerStarted = true
        // Blocking reads must not occupy a cooperative-pool thread for the life
        // of the connection, so a dedicated thread feeds an ordered stream.
        let descriptor = self.descriptor
        var timeout = timeval(tv_sec: 0, tv_usec: 0)   // blocking again
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let stream = AsyncStream<(DBusMessage, [Int32])> { continuation in
            let thread = Thread {
                var pending = [UInt8]()
                var pendingDescriptors = [Int32]()
                while true {
                    guard let chunk = try? UnixSocketMessaging.receive(capacity: 256 * 1024, over: descriptor),
                          !chunk.bytes.isEmpty else { break }
                    pending.append(contentsOf: chunk.bytes)
                    pendingDescriptors.append(contentsOf: chunk.descriptors)
                    // `try?` on an `Int?`-returning call flattens to `Int?`.
                    while let total = try? DBusMessage.totalLength(of: pending), pending.count >= total {
                        let slice = Array(pending[0..<total])
                        pending.removeFirst(total)
                        guard let message = try? DBusMessage.decode(slice) else { continue }
                        let taken = Array(pendingDescriptors.prefix(Int(message.unixFDCount)))
                        pendingDescriptors.removeFirst(min(taken.count, pendingDescriptors.count))
                        continuation.yield((message, taken))
                    }
                }
                // The reader closes the descriptor as it leaves, because it is
                // the last thing using it. Closing from `close()` instead would
                // race a `recvmsg` still in flight, and a descriptor number is
                // reused immediately — that misdirects someone else's I/O
                // rather than merely leaking.
                Darwin.close(descriptor)
                continuation.finish()
            }
            thread.name = "com.multiemu.dbus.reader"
            thread.stackSize = 512 * 1024
            thread.start()
        }

        readerTask = Task { [weak self] in
            for await (message, descriptors) in stream {
                await self?.dispatch(message, descriptors: descriptors)
            }
            await self?.handleClosed()
        }
    }

    private func dispatch(_ message: DBusMessage, descriptors: [Int32]) async {
        dbusTrace("recv \(message.kind) \(message.interface ?? "-").\(message.member ?? "-") serial=\(message.serial) reply=\(message.replySerial.map(String.init) ?? "-") fds=\(descriptors.count)")
        receivedDescriptors.append(contentsOf: descriptors)
        switch message.kind {
        case .methodReturn, .error:
            guard let serial = message.replySerial,
                  let continuation = pendingCalls.removeValue(forKey: serial) else { return }
            if message.kind == .error {
                continuation.resume(throwing: Failure.callFailed(
                    name: message.errorName ?? "org.freedesktop.DBus.Error.Failed",
                    message: message.body.first?.stringValue ?? ""
                ))
            } else {
                continuation.resume(returning: message)
            }

        case .methodCall:
            let reply = await handler?(message)
            if message.flags.contains(.noReplyExpected) { return }
            var response = reply ?? DBusMessage(
                kind: .error,
                errorName: "org.freedesktop.DBus.Error.UnknownMethod",
                body: [.string("\(message.interface ?? "?").\(message.member ?? "?") is not implemented")]
            )
            response.replySerial = message.serial
            response.serial = takeSerial()
            try? write(response, descriptors: [])

        case .signal:
            _ = await handler?(message)
        }
    }

    private func handleClosed() {
        isOpen = false
        let waiting = pendingCalls
        pendingCalls.removeAll()
        for (_, continuation) in waiting { continuation.resume(throwing: Failure.closed) }
    }

    private func takeSerial() -> UInt32 {
        defer { nextSerial &+= 1 }
        return nextSerial
    }

    private func write(_ message: DBusMessage, descriptors: [Int32]) throws {
        let bytes = try message.encoded()
        try UnixSocketMessaging.send(payload: bytes, descriptors: descriptors, over: descriptor)
    }

    // MARK: - Calls

    /// Sends a method call and waits for its reply.
    @discardableResult
    public func call(
        path: String,
        interface: String,
        member: String,
        body: [DBusValue] = [],
        descriptors: [Int32] = [],
        timeout: Duration = .seconds(10)
    ) async throws -> DBusMessage {
        guard isOpen else { throw Failure.closed }
        var message = DBusMessage(
            kind: .methodCall,
            serial: takeSerial(),
            path: path,
            interface: interface,
            member: member,
            body: body,
            unixFDCount: UInt32(descriptors.count)
        )
        let serial = message.serial

        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.failPending(serial: serial, member: member)
        }
        defer { watchdog.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            pendingCalls[serial] = continuation
            do {
                dbusTrace("send call \(interface).\(member) serial=\(serial) fds=\(descriptors.count)")
                try write(message, descriptors: descriptors)
            } catch {
                pendingCalls.removeValue(forKey: serial)
                continuation.resume(throwing: error)
            }
            message.serial = serial
        }
    }

    private func failPending(serial: UInt32, member: String) {
        guard let continuation = pendingCalls.removeValue(forKey: serial) else { return }
        continuation.resume(throwing: Failure.timedOut(member: member))
    }

    public func close() {
        // Deliberately NOT guarded on `isOpen`. The peer usually hangs up first
        // — QEMU exits, the reader sees EOF and `handleClosed()` clears the
        // flag — and an `isOpen` guard would skip the release on exactly the
        // path that always happens.
        readerTask?.cancel()
        isOpen = false
        // Unblock a reader parked in recvmsg. It then closes the descriptor on
        // its way out.
        shutdown(descriptor, SHUT_RDWR)
        if !readerStarted, !descriptorReleased {
            // No reader was ever started — a handshake that failed early — so
            // nothing else will release it.
            descriptorReleased = true
            Darwin.close(descriptor)
        }
    }
}
