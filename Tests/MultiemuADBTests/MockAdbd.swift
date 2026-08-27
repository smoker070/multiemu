import Darwin
import Foundation
@testable import MultiemuADB

/// A test double that plays `adbd` over a real loopback socket.
///
/// **Why a socket and not an injected transport.** The parts of this client
/// most likely to be wrong are the ones that touch the wire: framing across
/// chunk boundaries, flow control, the acknowledgement adbd waits for before it
/// sends more. A fake transport that hands over whole messages tests none of
/// them. This speaks the real protocol through the real socket path, so the
/// only thing not exercised is Android itself.
///
/// It also makes the authentication path testable at all: the images this
/// project runs are `userdebug` with `ro.adb.secure` unset and never send an
/// `AUTH`, so without a double the whole key exchange would ship unexercised.
final class MockAdbd: @unchecked Sendable {

    enum Authentication {
        /// Answer `CNXN` immediately, as a userdebug guest does.
        case none
        /// Send a token and accept whatever signature comes back.
        case acceptsAnySignature
        /// Send a token, reject the signature, then accept the public key.
        case demandsPublicKey
        /// Never accept anything.
        case rejectsEverything
    }

    /// A file the mock's `sync:` service serves and stores.
    struct StoredFile {
        var data: Data
        var mode: UInt32
    }

    private let listener: Int32
    private(set) var port: Int = 0
    private var thread: Thread?
    private let authentication: Authentication

    /// Shell commands the mock knows, and what they print.
    ///
    /// Set before `start()`; read from connection threads.
    var shellResponses: [String: String] {
        get { lock.lock(); defer { lock.unlock() }; return storedShellResponses }
        set { lock.lock(); defer { lock.unlock() }; storedShellResponses = newValue }
    }
    private var storedShellResponses: [String: String] = [:]

    /// Anything not in `shellResponses`.
    var defaultShellResponse: String {
        get { lock.lock(); defer { lock.unlock() }; return storedDefaultResponse }
        set { lock.lock(); defer { lock.unlock() }; storedDefaultResponse = newValue }
    }
    private var storedDefaultResponse = ""
    /// The mock's filesystem for `sync:`.
    private let lock = NSLock()
    private var files: [String: StoredFile] = [:]
    private var offeredPublicKey: Data?
    private var recordedShellCommands: [String] = []
    private var pendingPushFailure: String?

    /// Set when the client offered its public key, so a test can assert it.
    ///
    /// Read under the same lock that writes it: the mock records on its own
    /// thread and the test reads on another, and an unsynchronised read of a
    /// value written elsewhere is a race whether or not it usually works.
    var receivedPublicKey: Data? {
        lock.lock(); defer { lock.unlock() }
        return offeredPublicKey
    }

    /// Every shell command the client asked for, in order.
    var shellCommands: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedShellCommands
    }

    /// Fails the next `SEND` with this message, to exercise the refusal path.
    var failNextPush: String? {
        get { lock.lock(); defer { lock.unlock() }; return pendingPushFailure }
        set { lock.lock(); defer { lock.unlock() }; pendingPushFailure = newValue }
    }

    init(authentication: Authentication = .none) throws {
        self.authentication = authentication
        listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw MockFailure.socket("socket()") }

        var reuse: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        // Port 0: the kernel picks a free one, so parallel tests never collide.
        address.sin_port = 0
        // Loopback only. A test listener on a wildcard address would expose a
        // fake root shell to the local network for the length of the run.
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw MockFailure.socket("bind()") }
        guard Darwin.listen(listener, 4) == 0 else { throw MockFailure.socket("listen()") }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &length)
            }
        }
        port = Int(UInt16(bigEndian: actual.sin_port))
    }

    enum MockFailure: Error { case socket(String) }

    func store(_ data: Data, at path: String, mode: UInt32 = 0o644) {
        lock.lock(); defer { lock.unlock() }
        files[path] = StoredFile(data: data, mode: mode)
    }

    func file(at path: String) -> StoredFile? {
        lock.lock(); defer { lock.unlock() }
        return files[path]
    }

    /// Serves connections until `stop()`.
    func start() {
        let thread = Thread { [weak self] in self?.serve() }
        thread.name = "multiemu.mock-adbd"
        thread.start()
        self.thread = thread
    }

    func stop() {
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
    }

    /// Accepts forever, handing each connection to its own thread.
    ///
    /// Both details are load-bearing and were added after the suite went flaky.
    /// The client opens a fresh connection per operation, so a mock that
    /// handled them one at a time serialised the whole test behind whichever
    /// connection was still open — and a mock blocked in `recv` with no timeout
    /// never came back at all, wedging every later test with a timeout in a
    /// test that had nothing wrong with it. A test double that can hang is a
    /// test double that reports failures in the wrong place.
    private func serve() {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var time = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
            let thread = Thread { [weak self] in
                self?.handle(client)
                Darwin.close(client)
            }
            thread.name = "multiemu.mock-adbd.connection"
            thread.start()
        }
    }

    // MARK: - Wire

    private func receiveExactly(_ fd: Int32, _ count: Int) -> Data? {
        var buffer = Data()
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        while buffer.count < count {
            let read = recv(fd, &scratch, min(count - buffer.count, scratch.count), 0)
            guard read > 0 else { return nil }
            buffer.append(contentsOf: scratch[0..<read])
        }
        return buffer
    }

    private func readMessage(_ fd: Int32) -> ADBMessage? {
        guard let headerData = receiveExactly(fd, ADBMessage.headerSize),
              let header = try? ADBMessage.decodeHeader(headerData) else { return nil }
        let payload = header.payloadLength > 0
            ? receiveExactly(fd, header.payloadLength) : Data()
        guard let payload else { return nil }
        return ADBMessage(command: header.command, arg0: header.arg0, arg1: header.arg1,
                          payload: payload)
    }

    @discardableResult
    private func send(_ fd: Int32, _ message: ADBMessage) -> Bool {
        var remaining = message.encoded
        while !remaining.isEmpty {
            let sent = remaining.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            guard sent > 0 else { return false }
            remaining = remaining.dropFirst(sent)
        }
        return true
    }

    private static let banner = "device::ro.product.name=mock;features=shell_v2,cmd,stat_v2"

    private func handle(_ fd: Int32) {
        guard let opening = readMessage(fd),
              opening.command == ADBMessage.Command.connect.code else { return }

        switch authentication {
        case .none:
            send(fd, ADBMessage(.connect, arg0: ADBConnection.version,
                                arg1: UInt32(ADBMessage.maximumPayload),
                                payload: Data((Self.banner + "\0").utf8)))
        case .acceptsAnySignature:
            send(fd, ADBMessage(.auth, arg0: ADBMessage.AuthKind.token.rawValue,
                                payload: Data(repeating: 0xA5, count: ADBKey.tokenSize)))
            guard let reply = readMessage(fd),
                  reply.arg0 == ADBMessage.AuthKind.signature.rawValue,
                  // A real adbd verifies this; the point here is that a
                  // signature of the right size arrived at the right moment.
                  reply.payload.count == ADBKey.modulusBytes else { return }
            send(fd, ADBMessage(.connect, arg0: ADBConnection.version,
                                arg1: UInt32(ADBMessage.maximumPayload),
                                payload: Data((Self.banner + "\0").utf8)))
        case .demandsPublicKey:
            send(fd, ADBMessage(.auth, arg0: ADBMessage.AuthKind.token.rawValue,
                                payload: Data(repeating: 0xA5, count: ADBKey.tokenSize)))
            guard let signature = readMessage(fd),
                  signature.arg0 == ADBMessage.AuthKind.signature.rawValue else { return }
            // Pretend the key is unknown: send a second token, which is how
            // adbd asks the client to offer its public key.
            send(fd, ADBMessage(.auth, arg0: ADBMessage.AuthKind.token.rawValue,
                                payload: Data(repeating: 0x5A, count: ADBKey.tokenSize)))
            guard let offered = readMessage(fd),
                  offered.arg0 == ADBMessage.AuthKind.publicKey.rawValue else { return }
            lock.lock(); offeredPublicKey = offered.payload; lock.unlock()
            send(fd, ADBMessage(.connect, arg0: ADBConnection.version,
                                arg1: UInt32(ADBMessage.maximumPayload),
                                payload: Data((Self.banner + "\0").utf8)))
        case .rejectsEverything:
            send(fd, ADBMessage(.auth, arg0: ADBMessage.AuthKind.token.rawValue,
                                payload: Data(repeating: 0xA5, count: ADBKey.tokenSize)))
            _ = readMessage(fd)
            send(fd, ADBMessage(.auth, arg0: ADBMessage.AuthKind.token.rawValue,
                                payload: Data(repeating: 0x5A, count: ADBKey.tokenSize)))
            _ = readMessage(fd)
            send(fd, ADBMessage(.auth, arg0: ADBMessage.AuthKind.token.rawValue,
                                payload: Data(repeating: 0x11, count: ADBKey.tokenSize)))
            return
        }

        // One stream at a time, matching the client.
        let remoteID: UInt32 = 7
        while let open = readMessage(fd) {
            guard open.command == ADBMessage.Command.open.code else { continue }
            let localID = open.arg0
            var service = String(decoding: open.payload, as: UTF8.self)
            if service.hasSuffix("\0") { service.removeLast() }
            send(fd, ADBMessage(.okay, arg0: remoteID, arg1: localID))

            if service.hasPrefix("shell:") {
                let command = String(service.dropFirst("shell:".count))
                lock.lock(); recordedShellCommands.append(command); lock.unlock()
                let response = shellResponses[command] ?? defaultShellResponse
                if !response.isEmpty {
                    send(fd, ADBMessage(.write, arg0: remoteID, arg1: localID,
                                        payload: Data(response.utf8)))
                    // The client acknowledges; consume it.
                    _ = readMessage(fd)
                }
                send(fd, ADBMessage(.close, arg0: remoteID, arg1: localID))
                _ = readMessage(fd)
            } else if service == "sync:" {
                serveSync(fd, remoteID: remoteID, localID: localID)
            } else {
                send(fd, ADBMessage(.close, arg0: remoteID, arg1: localID))
            }
        }
    }

    /// The `sync:` service, reassembling messages from stream chunks.
    private func serveSync(_ fd: Int32, remoteID: UInt32, localID: UInt32) {
        var buffer = Data()

        func pump() -> Bool {
            guard let message = readMessage(fd) else { return false }
            if message.command == ADBMessage.Command.write.code {
                buffer.append(message.payload)
                send(fd, ADBMessage(.okay, arg0: remoteID, arg1: localID))
                return true
            }
            if message.command == ADBMessage.Command.okay.code { return true }
            return false
        }

        func take(_ count: Int) -> Data? {
            while buffer.count < count {
                if !pump() { return nil }
            }
            let head = Data(buffer.prefix(count))
            buffer = buffer.dropFirst(count)
            return head
        }

        func header() -> (String, UInt32)? {
            guard let bytes = take(8) else { return nil }
            let id = ADBMessage.name(of: bytes.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
            })
            let value = bytes.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            }
            return (id, value)
        }

        func write(_ data: Data) {
            send(fd, ADBMessage(.write, arg0: remoteID, arg1: localID, payload: data))
            _ = readMessage(fd)
        }

        while let (id, value) = header() {
            switch id {
            case "SEND":
                guard let pathData = take(Int(value)) else { return }
                let combined = String(decoding: pathData, as: UTF8.self)
                let comma = combined.lastIndex(of: ",")
                let path = comma.map { String(combined[combined.startIndex..<$0]) } ?? combined
                let mode = comma.flatMap { UInt32(combined[combined.index(after: $0)...]) } ?? 0o644
                var contents = Data()
                var failed: String?
                loop: while let (chunkID, chunkValue) = header() {
                    switch chunkID {
                    case "DATA":
                        guard let chunk = take(Int(chunkValue)) else { return }
                        contents.append(chunk)
                    case "DONE":
                        break loop
                    default:
                        failed = "unexpected \(chunkID)"
                        break loop
                    }
                }
                if let message = failNextPush {
                    failNextPush = nil
                    var reply = ADBSync.request(.fail, value: UInt32(message.utf8.count))
                    reply.append(Data(message.utf8))
                    write(reply)
                } else if let failed {
                    var reply = ADBSync.request(.fail, value: UInt32(failed.utf8.count))
                    reply.append(Data(failed.utf8))
                    write(reply)
                } else {
                    store(contents, at: path, mode: mode)
                    write(ADBSync.request(.okay, value: 0))
                }

            case "RECV":
                guard let pathData = take(Int(value)) else { return }
                let path = String(decoding: pathData, as: UTF8.self)
                guard let stored = file(at: path) else {
                    let message = "No such file or directory"
                    var reply = ADBSync.request(.fail, value: UInt32(message.utf8.count))
                    reply.append(Data(message.utf8))
                    write(reply)
                    continue
                }
                var remaining = stored.data
                // Deliberately split into several DATA messages so the client's
                // reassembly is exercised even for a small file.
                let chunk = max(1, remaining.count / 3 + 1)
                while !remaining.isEmpty {
                    let slice = remaining.prefix(chunk)
                    remaining = remaining.dropFirst(slice.count)
                    var reply = ADBSync.request(.data, value: UInt32(slice.count))
                    reply.append(contentsOf: slice)
                    write(reply)
                }
                write(ADBSync.request(.done, value: 0))

            case "STAT":
                guard let pathData = take(Int(value)) else { return }
                let path = String(decoding: pathData, as: UTF8.self)
                let stored = file(at: path)
                var reply = ADBSync.request(.stat, value: stored?.mode ?? 0)
                var size = UInt32(stored?.data.count ?? 0).littleEndian
                var time = UInt32(0).littleEndian
                withUnsafeBytes(of: &size) { reply.append(contentsOf: $0) }
                withUnsafeBytes(of: &time) { reply.append(contentsOf: $0) }
                write(reply)

            case "QUIT":
                send(fd, ADBMessage(.close, arg0: remoteID, arg1: localID))
                return

            default:
                return
            }
        }
    }
}
