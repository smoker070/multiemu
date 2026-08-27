import Foundation

/// The `sync:` service — how files move over ADB.
///
/// A second, smaller protocol carried inside one ADB stream. Its messages are
/// an eight-byte header (a four-character id and a 32-bit little-endian
/// number) followed by data, and they do not line up with the chunk boundaries
/// of the stream underneath, so everything here reads through a buffer rather
/// than assuming one read yields one message. Assuming otherwise works on small
/// files and fails on large ones, which is the worst way for it to fail.
public struct ADBSync {

    public enum Identifier: String, Sendable {
        case stat = "STAT"
        case list = "LIST"
        case send = "SEND"
        case receive = "RECV"
        case data = "DATA"
        case done = "DONE"
        case okay = "OKAY"
        case fail = "FAIL"
        case quit = "QUIT"

        var code: UInt32 { ADBMessage.code(for: rawValue) }
    }

    /// The largest payload one `DATA` message may carry.
    ///
    /// adbd's own `SYNC_DATA_MAX`. A larger chunk is not an optimisation: the
    /// peer rejects it and closes the stream.
    public static let dataChunkLimit = 64 * 1024

    public enum Failure: Error, CustomStringConvertible {
        case refused(String)
        case unexpected(String)
        case truncated
        case pathTooLong(Int)

        public var description: String {
            switch self {
            case let .refused(message): return "The guest refused the transfer: \(message)"
            case let .unexpected(id): return "Unexpected sync message `\(id)`."
            case .truncated: return "The sync stream ended in the middle of a message."
            case let .pathTooLong(count):
                return "A guest path of \(count) bytes is longer than the sync protocol allows."
            }
        }
    }

    /// adbd rejects a path longer than this in one request.
    public static let maximumPathBytes = 1024

    /// Buffers the stream so an eight-byte header can be read from it even when
    /// the transport delivers the two halves in different chunks.
    final class Reader {
        private let connection: ADBConnection
        private var buffer = Data()
        private var ended = false

        init(_ connection: ADBConnection) { self.connection = connection }

        func take(_ count: Int) throws -> Data {
            while buffer.count < count {
                guard let chunk = try connection.readChunk() else {
                    ended = true
                    throw Failure.truncated
                }
                buffer.append(chunk)
            }
            let head = buffer.prefix(count)
            buffer = buffer.dropFirst(count)
            return Data(head)
        }

        func takeHeader() throws -> (id: String, value: UInt32) {
            let header = try take(8)
            let id = ADBMessage.name(of: header.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
            })
            let value = header.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            }
            return (id, value)
        }

        var isEnded: Bool { ended }
    }

    /// Encodes one request header, plus its path when the request carries one.
    public static func request(_ identifier: Identifier, value: UInt32) -> Data {
        var data = Data()
        withUnsafeBytes(of: identifier.code.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    public static func request(_ identifier: Identifier, path: String) throws -> Data {
        let bytes = Data(path.utf8)
        guard bytes.count <= maximumPathBytes else { throw Failure.pathTooLong(bytes.count) }
        var data = request(identifier, value: UInt32(bytes.count))
        data.append(bytes)
        return data
    }

    let connection: ADBConnection

    public init(connection: ADBConnection) { self.connection = connection }

    /// Opens the `sync:` service. The stream stays open for several transfers.
    public func begin() throws {
        try connection.openStream(service: "sync:")
    }

    public func end() {
        // Politeness, not a requirement: adbd closes the stream on QUIT, and a
        // peer that has already gone simply never reads it.
        try? connection.writeChunk(Self.request(.quit, value: 0))
        connection.closeStream()
    }

    /// Sends a local file to `remotePath` with `mode`.
    ///
    /// Returns the number of bytes sent, so a caller can report a rate without
    /// stat-ing the file a second time.
    @discardableResult
    public func push(data: Data, to remotePath: String, mode: UInt32 = 0o644,
                     modified: Date = Date()) throws -> Int {
        // The SEND request's "path" is the destination and the mode, joined by
        // a comma — a quirk of the protocol, not a convention worth hiding.
        try connection.writeChunk(try Self.request(.send, path: "\(remotePath),\(mode)"))

        var remaining = data
        while !remaining.isEmpty {
            let slice = remaining.prefix(Self.dataChunkLimit)
            remaining = remaining.dropFirst(slice.count)
            var message = Self.request(.data, value: UInt32(slice.count))
            message.append(contentsOf: slice)
            try connection.writeChunk(message)
        }

        try connection.writeChunk(
            Self.request(.done, value: UInt32(max(0, modified.timeIntervalSince1970))))

        let reader = Reader(connection)
        let (id, value) = try reader.takeHeader()
        switch id {
        case Identifier.okay.rawValue:
            return data.count
        case Identifier.fail.rawValue:
            let message = try reader.take(Int(min(value, UInt32(Self.maximumPathBytes))))
            throw Failure.refused(String(decoding: message, as: UTF8.self))
        default:
            throw Failure.unexpected(id)
        }
    }

    /// Reads `remotePath` back from the guest.
    public func pull(_ remotePath: String, sizeLimit: Int) throws -> Data {
        try connection.writeChunk(try Self.request(.receive, path: remotePath))
        let reader = Reader(connection)
        var output = Data()
        while true {
            let (id, value) = try reader.takeHeader()
            switch id {
            case Identifier.data.rawValue:
                guard output.count + Int(value) <= sizeLimit else {
                    throw Failure.refused(
                        "the file is larger than the \(sizeLimit)-byte limit for this transfer")
                }
                output.append(try reader.take(Int(value)))
            case Identifier.done.rawValue:
                return output
            case Identifier.fail.rawValue:
                let message = try reader.take(Int(min(value, UInt32(Self.maximumPathBytes))))
                throw Failure.refused(String(decoding: message, as: UTF8.self))
            default:
                throw Failure.unexpected(id)
            }
        }
    }

    public struct Entry: Sendable, Equatable {
        public var mode: UInt32
        public var size: UInt32
        public var modifiedEpoch: UInt32
        /// adbd answers a `STAT` for a missing path with all fields zero
        /// rather than a failure, so "does it exist" is a mode check.
        public var exists: Bool { mode != 0 }
    }

    public func stat(_ remotePath: String) throws -> Entry {
        try connection.writeChunk(try Self.request(.stat, path: remotePath))
        let reader = Reader(connection)
        let (id, mode) = try reader.takeHeader()
        guard id == Identifier.stat.rawValue else { throw Failure.unexpected(id) }
        let rest = try reader.take(8)
        let size = rest.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        let time = rest.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        }
        return Entry(mode: mode, size: size, modifiedEpoch: time)
    }
}
