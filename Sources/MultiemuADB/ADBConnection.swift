import Darwin
import Foundation

/// A connection to one `adbd`, speaking the wire protocol directly.
///
/// **Why this is first-party code.** Google's `platform-tools` `adb` is not
/// redistributable — see `docs/DEPENDENCIES-AND-LICENSING.md` §4 — so shipping
/// it is not an option, and building AOSP's client would add a large native
/// build to a project with no third-party dependencies. The protocol is a
/// 24-byte header and six message kinds, so the client is written here instead.
/// That removes the redistribution question rather than answering it.
///
/// **Threading.** Every call blocks. The descriptor is owned by whichever
/// thread is using the connection and is never shared; callers must keep it off
/// the cooperative pool, because looping a blocking call inside a `Task` starves
/// the executor — a mistake that has already cost this project one measurement
/// harness that died mid-run with no report.
///
/// **One stream at a time.** The protocol multiplexes streams by id, but
/// nothing here needs two at once, and a multiplexer that is never exercised
/// with two streams is a multiplexer that does not work. `openStream` therefore
/// refuses while another stream is open.
public final class ADBConnection {

    public enum Failure: Error, CustomStringConvertible {
        case connectFailed(String)
        case peerClosed(during: String)
        case timedOut(during: String)
        case unexpected(command: String, during: String)
        case authenticationRejected
        case authenticationRequiredWithoutKey
        case streamRefused(service: String)
        case streamAlreadyOpen
        case malformed(String)

        public var description: String {
            switch self {
            case let .connectFailed(detail): return "Could not reach adbd: \(detail)"
            case let .peerClosed(during): return "adbd closed the connection while \(during)."
            case let .timedOut(during): return "adbd did not answer while \(during)."
            case let .unexpected(command, during):
                return "Unexpected ADB message \(command) while \(during)."
            case .authenticationRejected:
                return "adbd rejected this host's key. Accept it on the device, or delete the "
                    + "device's `adb_keys` and reconnect."
            case .authenticationRequiredWithoutKey:
                return "adbd asked for authentication and no key was supplied."
            case let .streamRefused(service):
                return "adbd refused to open `\(service)`."
            case .streamAlreadyOpen:
                return "This connection already has a stream open; close it first."
            case let .malformed(detail): return "Malformed ADB exchange: \(detail)"
            }
        }
    }

    /// The protocol version this client announces.
    ///
    /// Set from `ADBMessage.Version`, and the choice has a consequence worth
    /// stating: at this version adbd sends zero payload checksums, so the
    /// checksum is not an integrity check for this connection. What still is:
    /// the header magic, which catches a desynchronised stream immediately, and
    /// the payload-length bound, which is what stops a guest making this
    /// process allocate at will. Checksums were verified in an earlier draft
    /// and rejected the guest's own `CNXN` reply.
    public static let version: UInt32 = ADBMessage.Version.skipsChecksums

    /// The lower of this client's version and the guest's, as adb negotiates
    /// it. Until `CNXN` comes back there is nothing to verify against, so it
    /// starts at this client's version.
    public private(set) var negotiatedVersion: UInt32 = ADBConnection.version

    /// The single stream id this client uses. See the type comment.
    private static let localStreamID: UInt32 = 1

    public let host: String
    public let port: Int
    private let key: ADBKey?
    private let timeout: TimeInterval

    private var descriptor: Int32 = -1
    private var streamIsOpen = false
    /// adbd's id for the open stream, needed on every acknowledgement.
    private var remoteStreamID: UInt32 = 0

    /// What adbd said about itself in its `CNXN` reply.
    public private(set) var banner: String = ""

    public init(host: String = "127.0.0.1", port: Int, key: ADBKey? = nil,
                timeout: TimeInterval = 20) {
        self.host = host
        self.port = port
        self.key = key
        self.timeout = timeout
    }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    // MARK: - Socket

    private func openSocket() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.connectFailed("socket(): \(Self.errnoText())") }

        var time = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        // Without this a write to a closed connection raises SIGPIPE, which
        // kills the whole process rather than failing the call.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr(host)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let detail = Self.errnoText()
            Darwin.close(fd)
            throw Failure.connectFailed("connect(): \(detail)")
        }
        descriptor = fd
    }

    private func sendAll(_ data: Data, during activity: String) throws {
        var remaining = data
        while !remaining.isEmpty {
            let sent = remaining.withUnsafeBytes { buffer in
                send(descriptor, buffer.baseAddress, buffer.count, 0)
            }
            if sent > 0 {
                remaining = remaining.dropFirst(sent)
                continue
            }
            if sent < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                throw Failure.timedOut(during: activity)
            }
            throw Failure.peerClosed(during: activity)
        }
    }

    private func receiveExactly(_ count: Int, during activity: String) throws -> Data {
        guard count > 0 else { return Data() }
        var buffer = Data(capacity: count)
        var scratch = [UInt8](repeating: 0, count: min(count, 64 * 1024))
        while buffer.count < count {
            let wanted = min(count - buffer.count, scratch.count)
            let read = recv(descriptor, &scratch, wanted, 0)
            if read > 0 {
                buffer.append(contentsOf: scratch[0..<read])
                continue
            }
            if read < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                throw Failure.timedOut(during: activity)
            }
            throw Failure.peerClosed(during: activity)
        }
        return buffer
    }

    /// Reads one message and checks it against the header that announced it.
    private func readMessage(during activity: String) throws -> ADBMessage {
        let headerData = try receiveExactly(ADBMessage.headerSize, during: activity)
        let header = try ADBMessage.decodeHeader(headerData)
        let payload = try receiveExactly(header.payloadLength, during: activity)
        try ADBMessage.verify(payload: payload, against: header,
                              negotiatedVersion: negotiatedVersion)
        return ADBMessage(command: header.command, arg0: header.arg0, arg1: header.arg1,
                          payload: payload)
    }

    private func write(_ message: ADBMessage, during activity: String) throws {
        try sendAll(message.encoded, during: activity)
    }

    // MARK: - Handshake

    /// Completes `CNXN`, answering an `AUTH` challenge if adbd makes one.
    ///
    /// The `AUTH` exchange is: adbd sends `TOKEN`, the host replies with a
    /// `SIGNATURE`, and adbd either connects or sends another `TOKEN`. A second
    /// token means the signature was not recognised, at which point the host
    /// offers its public key once and waits for the user to accept it on the
    /// device. Offering the key first would train users to accept keys.
    public func connect() throws {
        try openSocket()
        try write(ADBMessage(.connect, arg0: Self.version,
                             arg1: UInt32(ADBMessage.maximumPayload),
                             payload: Data("host::multiemu\0".utf8)),
                  during: "sending CNXN")

        var offeredPublicKey = false
        while true {
            let message = try readMessage(during: "waiting for the CNXN reply")
            switch message.command {
            case ADBMessage.Command.connect.code:
                negotiatedVersion = min(Self.version, message.arg0)
                banner = String(decoding: message.payload, as: UTF8.self)
                    .split(separator: "\0").first.map(String.init) ?? ""
                return

            case ADBMessage.Command.auth.code:
                guard message.arg0 == ADBMessage.AuthKind.token.rawValue else {
                    throw Failure.malformed("AUTH with kind \(message.arg0)")
                }
                guard let key else { throw Failure.authenticationRequiredWithoutKey }
                if offeredPublicKey {
                    // We signed, we offered the key, and adbd is still asking.
                    throw Failure.authenticationRejected
                }
                let signature = try key.signature(forToken: message.payload)
                try write(ADBMessage(.auth, arg0: ADBMessage.AuthKind.signature.rawValue,
                                     payload: signature),
                          during: "sending the signed token")
                // If the next message is another token, the signature was not
                // known; offer the key so the device can prompt.
                let next = try readMessage(during: "waiting after signing the token")
                if next.command == ADBMessage.Command.connect.code {
                    negotiatedVersion = min(Self.version, next.arg0)
                    banner = String(decoding: next.payload, as: UTF8.self)
                        .split(separator: "\0").first.map(String.init) ?? ""
                    return
                }
                guard next.command == ADBMessage.Command.auth.code else {
                    throw Failure.unexpected(command: ADBMessage.name(of: next.command),
                                             during: "authenticating")
                }
                offeredPublicKey = true
                try write(ADBMessage(.auth, arg0: ADBMessage.AuthKind.publicKey.rawValue,
                                     payload: try key.androidPublicKeyBlob()),
                          during: "offering the public key")

            case ADBMessage.Command.close.code:
                throw Failure.peerClosed(during: "the CNXN handshake")

            default:
                throw Failure.unexpected(command: ADBMessage.name(of: message.command),
                                         during: "the CNXN handshake")
            }
        }
    }

    // MARK: - Streams

    /// Opens an adbd service — `shell:…`, `exec:…`, `sync:` — as a stream.
    public func openStream(service: String) throws {
        guard !streamIsOpen else { throw Failure.streamAlreadyOpen }
        try write(ADBMessage(.open, arg0: Self.localStreamID,
                             payload: Data((service + "\0").utf8)),
                  during: "opening \(service)")
        let reply = try readMessage(during: "opening \(service)")
        switch reply.command {
        case ADBMessage.Command.okay.code:
            remoteStreamID = reply.arg0
            streamIsOpen = true
        case ADBMessage.Command.close.code:
            throw Failure.streamRefused(service: service)
        default:
            throw Failure.unexpected(command: ADBMessage.name(of: reply.command),
                                     during: "opening \(service)")
        }
    }

    /// Reads the next chunk the guest wrote, or `nil` when the stream ends.
    ///
    /// Every `WRTE` is acknowledged before returning. adbd stops sending until
    /// it sees the `OKAY`, so a caller that forgets one hangs rather than
    /// failing — which is why acknowledgement lives here and not in callers.
    public func readChunk() throws -> Data? {
        guard streamIsOpen else { return nil }
        while true {
            let message = try readMessage(during: "reading the stream")
            switch message.command {
            case ADBMessage.Command.write.code:
                try write(ADBMessage(.okay, arg0: Self.localStreamID, arg1: message.arg0),
                          during: "acknowledging a chunk")
                return message.payload
            case ADBMessage.Command.okay.code:
                continue
            case ADBMessage.Command.close.code:
                streamIsOpen = false
                // The protocol asks for a CLSE in reply; a guest that has
                // already gone will not read it, so failure here is not one.
                try? write(ADBMessage(.close, arg0: Self.localStreamID, arg1: message.arg0),
                           during: "closing the stream")
                return nil
            default:
                throw Failure.unexpected(command: ADBMessage.name(of: message.command),
                                         during: "reading the stream")
            }
        }
    }

    /// Sends bytes to the open stream, waiting for the acknowledgement adbd's
    /// flow control requires before the next chunk.
    public func writeChunk(_ data: Data) throws {
        guard streamIsOpen else { throw Failure.malformed("no stream is open") }
        var remaining = data
        // adbd's own limit for one WRTE payload is the maximum announced in
        // CNXN; staying under it keeps the peer from closing the stream.
        let limit = ADBMessage.maximumPayload
        repeat {
            let chunk = remaining.prefix(limit)
            remaining = remaining.dropFirst(chunk.count)
            try write(ADBMessage(.write, arg0: Self.localStreamID, arg1: remoteStreamID,
                                 payload: Data(chunk)),
                      during: "writing to the stream")
            // Wait for the OKAY. Anything else means the stream is gone.
            while true {
                let reply = try readMessage(during: "waiting for a write acknowledgement")
                if reply.command == ADBMessage.Command.okay.code { break }
                if reply.command == ADBMessage.Command.close.code {
                    streamIsOpen = false
                    throw Failure.peerClosed(during: "writing to the stream")
                }
                throw Failure.unexpected(command: ADBMessage.name(of: reply.command),
                                         during: "writing to the stream")
            }
        } while !remaining.isEmpty
    }

    /// Reads the open stream until the guest closes it.
    public func readToEnd() throws -> Data {
        var output = Data()
        while let chunk = try readChunk() { output.append(chunk) }
        return output
    }

    public func closeStream() {
        guard streamIsOpen else { return }
        try? write(ADBMessage(.close, arg0: Self.localStreamID, arg1: remoteStreamID),
                   during: "closing the stream")
        streamIsOpen = false
    }

    public func close() {
        closeStream()
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    private static func errnoText() -> String { String(cString: strerror(errno)) }
}
