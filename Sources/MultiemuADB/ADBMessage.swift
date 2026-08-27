import Foundation

/// One ADB wire message: a 24-byte header and an optional payload.
///
/// The protocol is small — six 32-bit little-endian words followed by the
/// payload — and this type is the only place that knows its layout. It is pure
/// value code with no I/O so that the parts most easily got wrong (the
/// checksum, the magic, the length bound) can be tested without a guest.
///
/// Field order, from the header adbd sends and expects:
///
///     0  command     four ASCII bytes, little-endian ("CNXN" -> 0x4e584e43)
///     4  arg0
///     8  arg1
///    12  payload length
///    16  payload checksum  (sum of the payload bytes, wrapping)
///    20  magic             (command XOR 0xFFFFFFFF)
public struct ADBMessage: Sendable, Equatable {

    /// The message kinds this client uses.
    ///
    /// `SYNC` and `STLS` exist in the protocol and are deliberately absent:
    /// nothing here sends them, and a decoder that names a command it cannot
    /// handle invites a caller to assume it can.
    public enum Command: String, Sendable, CaseIterable {
        case connect = "CNXN"
        case auth = "AUTH"
        case open = "OPEN"
        case okay = "OKAY"
        case write = "WRTE"
        case close = "CLSE"

        public var code: UInt32 { ADBMessage.code(for: rawValue) }
    }

    /// AUTH sub-types, carried in `arg0` of an `AUTH` message.
    public enum AuthKind: UInt32, Sendable {
        /// adbd -> host: here is a 20-byte token, sign it.
        case token = 1
        /// host -> adbd: here is the token, signed with my private key.
        case signature = 2
        /// host -> adbd: here is my public key; ask the user to accept it.
        case publicKey = 3
    }

    public static let headerSize = 24

    /// Protocol versions, and the one that turned the checksum off.
    ///
    /// adbd stops computing payload checksums at `skipsChecksums` and sends
    /// zero instead. This is not a detail that can be inferred from a capture
    /// of one message: a zero checksum is indistinguishable from a correct
    /// checksum of an empty payload, so a client that verifies unconditionally
    /// works right up until the first non-empty message and then fails with a
    /// number that looks like corruption. This project met exactly that, on the
    /// `CNXN` reply, against a real guest.
    public enum Version {
        /// The oldest version adbd will negotiate.
        public static let minimum: UInt32 = 0x0100_0000
        /// At and above this, payload checksums are zero by definition.
        public static let skipsChecksums: UInt32 = 0x0100_0001
    }

    /// The largest payload this client will accept from the guest.
    ///
    /// adbd is told our maximum in `CNXN`; this is the same number used as an
    /// inbound bound so a corrupt or hostile length field cannot make the
    /// client allocate without limit. The guest is a security boundary — the
    /// brief says so — and "it told us the length" is not a reason to trust it.
    public static let maximumPayload = 256 * 1024

    public var command: UInt32
    public var arg0: UInt32
    public var arg1: UInt32
    public var payload: Data

    public init(command: UInt32, arg0: UInt32 = 0, arg1: UInt32 = 0, payload: Data = Data()) {
        self.command = command
        self.arg0 = arg0
        self.arg1 = arg1
        self.payload = payload
    }

    public init(_ command: Command, arg0: UInt32 = 0, arg1: UInt32 = 0, payload: Data = Data()) {
        self.init(command: command.code, arg0: arg0, arg1: arg1, payload: payload)
    }

    /// The four-character command code as adbd encodes it.
    ///
    /// Little-endian, so the first character is the low byte. Getting this
    /// backwards produces a message adbd silently ignores rather than an error,
    /// which is why it is one function used by both directions.
    public static func code(for text: String) -> UInt32 {
        var value: UInt32 = 0
        for (index, scalar) in text.unicodeScalars.prefix(4).enumerated() {
            value |= UInt32(scalar.value & 0xFF) << (8 * index)
        }
        return value
    }

    /// The printable form of a command code, for errors a human has to read.
    public static func name(of code: UInt32) -> String {
        let bytes = (0..<4).map { UInt8((code >> (8 * $0)) & 0xFF) }
        let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        guard printable else { return String(format: "0x%08x", code) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Sum of the payload bytes, wrapping — adbd's `checksum` field.
    ///
    /// Wrapping addition is the protocol's definition, not an oversight: a
    /// trapping `+` here would crash the client on any payload over ~16 MB of
    /// 0xFF bytes rather than produce the value adbd expects.
    public static func checksum(of payload: Data) -> UInt32 {
        payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }
    }

    public var encoded: Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        let words: [UInt32] = [
            command, arg0, arg1,
            UInt32(payload.count),
            Self.checksum(of: payload),
            command ^ 0xFFFF_FFFF,
        ]
        for word in words {
            withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(payload)
        return data
    }

    /// What a header says about the payload that follows it.
    public struct Header: Sendable, Equatable {
        public var command: UInt32
        public var arg0: UInt32
        public var arg1: UInt32
        public var payloadLength: Int
        public var payloadChecksum: UInt32
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case shortHeader(Int)
        case magicMismatch(command: UInt32, magic: UInt32)
        case payloadTooLarge(Int, limit: Int)
        case checksumMismatch(expected: UInt32, actual: UInt32)

        public var description: String {
            switch self {
            case let .shortHeader(count):
                return "An ADB header is \(ADBMessage.headerSize) bytes; got \(count)."
            case let .magicMismatch(command, magic):
                return "ADB header magic does not match its command: "
                    + "\(ADBMessage.name(of: command)) with magic \(String(format: "0x%08x", magic)). "
                    + "The stream is out of frame."
            case let .payloadTooLarge(length, limit):
                return "The guest announced a \(length)-byte payload; this client accepts \(limit)."
            case let .checksumMismatch(expected, actual):
                return "ADB payload checksum \(actual) does not match the announced \(expected)."
            }
        }
    }

    /// Reads a header, rejecting anything that cannot be a real one.
    ///
    /// The magic check is what catches a desynchronised stream immediately
    /// rather than several messages later: every valid header carries the
    /// command's own complement, so garbage almost never passes.
    public static func decodeHeader(_ data: Data) throws -> Header {
        guard data.count >= headerSize else { throw Failure.shortHeader(data.count) }
        let words: [UInt32] = (0..<6).map { index in
            data.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))
            }
        }
        guard words[0] ^ 0xFFFF_FFFF == words[5] else {
            throw Failure.magicMismatch(command: words[0], magic: words[5])
        }
        let length = Int(words[3])
        guard length <= maximumPayload else {
            throw Failure.payloadTooLarge(length, limit: maximumPayload)
        }
        return Header(command: words[0], arg0: words[1], arg1: words[2],
                      payloadLength: length, payloadChecksum: words[4])
    }

    /// Checks a payload against the checksum its header announced, when the
    /// negotiated version still defines one.
    ///
    /// At `Version.skipsChecksums` and above the field carries no information
    /// and checking it rejects every valid message. The bound on the payload
    /// length in `decodeHeader` is the check that actually protects this
    /// process, and it does not depend on the version.
    public static func verify(payload: Data, against header: Header,
                              negotiatedVersion: UInt32) throws {
        guard negotiatedVersion < Version.skipsChecksums else { return }
        let actual = checksum(of: payload)
        guard actual == header.payloadChecksum else {
            throw Failure.checksumMismatch(expected: header.payloadChecksum, actual: actual)
        }
    }
}
