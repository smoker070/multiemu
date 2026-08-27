import Foundation

/// A D-Bus message.
public struct DBusMessage: Sendable, Equatable {

    public enum Kind: UInt8, Sendable {
        case methodCall = 1
        case methodReturn = 2
        case error = 3
        case signal = 4
    }

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let noReplyExpected = Flags(rawValue: 0x01)
        public static let noAutoStart = Flags(rawValue: 0x02)
    }

    /// Header field codes from the specification.
    enum FieldCode: UInt8 {
        case path = 1
        case interface = 2
        case member = 3
        case errorName = 4
        case replySerial = 5
        case destination = 6
        case sender = 7
        case signature = 8
        case unixFDs = 9
    }

    public var kind: Kind
    public var flags: Flags
    public var serial: UInt32
    public var path: String?
    public var interface: String?
    public var member: String?
    public var errorName: String?
    public var replySerial: UInt32?
    public var destination: String?
    public var sender: String?
    public var body: [DBusValue]
    /// Number of descriptors travelling with this message via `SCM_RIGHTS`.
    public var unixFDCount: UInt32

    public init(
        kind: Kind,
        flags: Flags = [],
        serial: UInt32 = 0,
        path: String? = nil,
        interface: String? = nil,
        member: String? = nil,
        errorName: String? = nil,
        replySerial: UInt32? = nil,
        destination: String? = nil,
        sender: String? = nil,
        body: [DBusValue] = [],
        unixFDCount: UInt32 = 0
    ) {
        self.kind = kind
        self.flags = flags
        self.serial = serial
        self.path = path
        self.interface = interface
        self.member = member
        self.errorName = errorName
        self.replySerial = replySerial
        self.destination = destination
        self.sender = sender
        self.body = body
        self.unixFDCount = unixFDCount
    }

    public var bodySignature: String { body.map(\.signature).joined() }

    // MARK: Encoding

    /// Serialises the message.
    ///
    /// The fixed header is 12 bytes, followed by the header field array, then
    /// padding to an 8-byte boundary, then the body. The body is marshalled
    /// with a base offset so that its internal alignment is measured from the
    /// start of the message, as the specification requires.
    public func encoded() throws -> [UInt8] {
        var fields: [DBusValue] = []
        func field(_ code: FieldCode, _ value: DBusValue) {
            fields.append(.structure([.byte(code.rawValue), .variant(value)]))
        }
        if let path { field(.path, .objectPath(path)) }
        if let interface { field(.interface, .string(interface)) }
        if let member { field(.member, .string(member)) }
        if let errorName { field(.errorName, .string(errorName)) }
        if let replySerial { field(.replySerial, .uint32(replySerial)) }
        if let destination { field(.destination, .string(destination)) }
        if let sender { field(.sender, .string(sender)) }
        if !body.isEmpty { field(.signature, .signature(bodySignature)) }
        if unixFDCount > 0 { field(.unixFDs, .uint32(unixFDCount)) }

        // Body first, to learn its length. Its base offset is not yet known, so
        // it is marshalled twice: once to size it, once at the real offset.
        // Bodies here are small headers plus one big byte array, so the cost is
        // irrelevant next to correctness.
        var probe = DBusMarshaller(baseOffset: 0)
        for value in body { probe.append(value) }

        var header = DBusMarshaller(baseOffset: 0)
        header.append(UInt8(0x6C))            // 'l' — little endian
        header.append(kind.rawValue)
        header.append(flags.rawValue)
        header.append(UInt8(1))               // protocol version
        header.append(UInt32(probe.bytes.count))
        header.append(serial)
        header.append(DBusValue.array(element: "(yv)", values: fields))
        header.align(to: 8)

        var bodyMarshaller = DBusMarshaller(baseOffset: header.bytes.count)
        for value in body { bodyMarshaller.append(value) }

        var out = header.bytes
        out.append(contentsOf: bodyMarshaller.bytes)

        // Patch the body length: alignment inside the body depends on its start
        // offset, so the real length can differ from the probe's.
        withUnsafeBytes(of: UInt32(bodyMarshaller.bytes.count).littleEndian) { raw in
            for (index, byte) in raw.enumerated() { out[4 + index] = byte }
        }
        return out
    }

    // MARK: Decoding

    public enum DecodeFailure: Error, Equatable, CustomStringConvertible {
        case notEnoughData(needed: Int, available: Int)
        case unsupportedByteOrder(UInt8)
        case unknownMessageType(UInt8)

        public var description: String {
            switch self {
            case let .notEnoughData(needed, available):
                return "Incomplete D-Bus message: needed \(needed) bytes, have \(available)."
            case let .unsupportedByteOrder(raw):
                return "Unsupported D-Bus byte order marker 0x\(String(raw, radix: 16)); only little-endian ('l') is implemented."
            case let .unknownMessageType(raw):
                return "Unknown D-Bus message type \(raw)."
            }
        }
    }

    /// Total on-wire length of the message starting at `bytes`, or `nil` when
    /// the fixed header has not fully arrived yet.
    public static func totalLength(of bytes: [UInt8]) throws -> Int? {
        guard bytes.count >= 16 else { return nil }
        guard bytes[0] == 0x6C else { throw DecodeFailure.unsupportedByteOrder(bytes[0]) }
        var reader = DBusUnmarshaller(bytes, offset: 4)
        let bodyLength = Int(try reader.readUInt32())
        _ = try reader.readUInt32()                       // serial
        let fieldsLength = Int(try reader.readUInt32())   // header array length
        let headerEnd = 16 + fieldsLength
        let padded = headerEnd % 8 == 0 ? headerEnd : headerEnd + (8 - headerEnd % 8)
        return padded + bodyLength
    }

    public static func decode(_ bytes: [UInt8]) throws -> DBusMessage {
        guard let total = try totalLength(of: bytes), bytes.count >= total else {
            throw DecodeFailure.notEnoughData(
                needed: (try? totalLength(of: bytes)).flatMap { $0 } ?? 16,
                available: bytes.count
            )
        }
        guard let kind = Kind(rawValue: bytes[1]) else {
            throw DecodeFailure.unknownMessageType(bytes[1])
        }

        var reader = DBusUnmarshaller(bytes, offset: 2)
        let flags = Flags(rawValue: try reader.readByte())
        _ = try reader.readByte()                     // protocol version
        _ = try reader.readUInt32()                   // body length
        let serial = try reader.readUInt32()
        let fields = try reader.read(signature: "a(yv)")

        var message = DBusMessage(kind: kind, flags: flags, serial: serial)
        var signature = ""
        if case .array(_, let entries) = fields {
            for entry in entries {
                guard case .structure(let members) = entry, members.count == 2,
                      case .byte(let code) = members[0],
                      case .variant(let value) = members[1] else { continue }
                switch FieldCode(rawValue: code) {
                case .path: message.path = value.stringValue
                case .interface: message.interface = value.stringValue
                case .member: message.member = value.stringValue
                case .errorName: message.errorName = value.stringValue
                case .replySerial: message.replySerial = value.uint32Value
                case .destination: message.destination = value.stringValue
                case .sender: message.sender = value.stringValue
                case .signature: signature = value.stringValue ?? ""
                case .unixFDs: message.unixFDCount = value.uint32Value ?? 0
                case .none: break
                }
            }
        }

        try reader.align(to: 8)
        if !signature.isEmpty {
            message.body = try reader.readBody(signature: signature)
        }
        return message
    }
}
