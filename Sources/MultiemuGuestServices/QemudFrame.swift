import Foundation

/// The framing an Android guest uses on a virtio-console port to reach what it
/// believes is a host service.
///
/// Taken from the wire, not from documentation. A booting Android 17 guest
/// sends, on the port its sensors HAL was handed:
///
///     00 00 00 00   0c 00 00 00   "list-sensors"
///     └─ type       └─ length     └─ payload
///        (u32 LE)      (u32 LE)      `length` bytes
///
/// and then blocks in `read()` for a reply in the same shape. Until one
/// arrives the HAL never registers, `system_server` waits on it forever, and
/// the guest never reaches `sys.boot_completed`.
///
/// **The guest is untrusted here.** These bytes cross a boundary: they are
/// produced inside the guest and parsed by this process, on the host. The
/// length word in particular is a number a guest chooses and this process would
/// otherwise allocate on. Everything in this file is written on the assumption
/// that a guest may be broken or hostile, and nothing a guest sends is ever
/// interpreted as an instruction — only as data to be answered.
public enum QemudFrame {

    /// `[u32 type][u32 length]`.
    public static let headerBytes = 8

    /// Largest payload this will accept in one frame.
    ///
    /// The real commands are tens of bytes. The cap exists because the length
    /// word is guest-controlled: without it, a guest declaring 4 GiB would have
    /// the host reserve 4 GiB waiting for a body that never arrives. Generous
    /// enough that no legitimate command approaches it, small enough that the
    /// worst case is uninteresting.
    public static let maximumPayloadBytes = 64 * 1024

    /// Largest amount of not-yet-complete data held while waiting for the rest
    /// of a frame.
    ///
    /// A backstop rather than the real bound. What actually bounds held bytes
    /// is `maximumPayloadBytes`, checked before the length is used: after
    /// complete frames are drained, the remainder is by definition shorter than
    /// the one frame still arriving, so it cannot exceed a header plus a
    /// maximum payload. The check exists so that an unusual caller — one
    /// handing over a very large chunk in a single `ingest` — is refused rather
    /// than trusted.
    public static let maximumBufferedBytes = maximumPayloadBytes + headerBytes

    public struct Message: Sendable, Equatable {
        public var type: UInt32
        public var payload: Data

        public init(type: UInt32, payload: Data) {
            self.type = type
            self.payload = payload
        }

        /// The payload read as a command string, or `nil` when it is not UTF-8.
        ///
        /// Optional rather than lossy on purpose: a command this cannot decode
        /// is one it must not pretend to understand.
        public var command: String? {
            String(data: payload, encoding: .utf8)
        }
    }

    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case payloadTooLarge(declared: Int, limit: Int)
        case bufferOverflow(held: Int, limit: Int)

        public var description: String {
            switch self {
            case let .payloadTooLarge(declared, limit):
                return """
                    The guest declared a \(declared)-byte frame; this accepts at most \(limit). \
                    Refusing to allocate on a guest-supplied length.
                    """
            case let .bufferOverflow(held, limit):
                return """
                    \(held) bytes of an incomplete frame are buffered, over the \(limit)-byte \
                    limit. The guest is sending a frame it never finishes.
                    """
            }
        }
    }

    /// Encodes one message.
    public static func encode(type: UInt32, payload: Data) -> Data {
        var data = Data(capacity: headerBytes + payload.count)
        withUnsafeBytes(of: type.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }
}

/// Reassembles frames from a byte stream that arrives in arbitrary pieces.
///
/// A virtio-console read returns whatever happens to be available, so a frame
/// may be split across reads and several may arrive in one. Holding the
/// remainder between calls is the whole job.
public struct QemudDecoder: Sendable {

    private var buffer = Data()

    public init() {}

    /// Bytes currently held awaiting the rest of a frame. Exposed so a caller
    /// can assert the decoder is not accumulating.
    public var bufferedByteCount: Int { buffer.count }

    /// Adds freshly read bytes and returns every complete message in them.
    ///
    /// Throws on a frame this refuses to honour. A caller that catches one
    /// should close the connection rather than continue: once a length is
    /// rejected there is no way to know where the next frame begins, so
    /// carrying on would be parsing a stream at an unknown offset.
    public mutating func ingest(_ data: Data) throws -> [QemudFrame.Message] {
        buffer.append(data)

        var messages: [QemudFrame.Message] = []
        while true {
            guard buffer.count >= QemudFrame.headerBytes else { break }

            let type = buffer.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            }
            let declared = buffer.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            }

            // Checked before it is used for anything, and compared as Int so a
            // value near UInt32.max cannot wrap on the way.
            let length = Int(declared)
            guard length <= QemudFrame.maximumPayloadBytes else {
                throw QemudFrame.Failure.payloadTooLarge(
                    declared: length, limit: QemudFrame.maximumPayloadBytes)
            }

            let total = QemudFrame.headerBytes + length
            guard buffer.count >= total else { break }   // Body still in flight.

            let start = buffer.startIndex + QemudFrame.headerBytes
            let payload = Data(buffer[start..<(buffer.startIndex + total)])
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + total))
            messages.append(.init(type: type, payload: payload))
        }

        // Checked on what is left AFTER complete frames are taken out, not on
        // what arrived. Checking before draining rejected lengths this very
        // decoder advertises as legal: a legitimate maximum-size frame with any
        // byte of the next frame pipelined behind it exceeded the limit while
        // being perfectly well formed.
        //
        // The transient during `append` is bounded by the caller's read size,
        // which is ours and small; nothing here is sized by the guest.
        guard buffer.count <= QemudFrame.maximumBufferedBytes else {
            throw QemudFrame.Failure.bufferOverflow(
                held: buffer.count, limit: QemudFrame.maximumBufferedBytes)
        }
        return messages
    }
}
