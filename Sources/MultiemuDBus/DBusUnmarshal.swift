import Foundation

/// Reads D-Bus values from little-endian wire format.
///
/// Every read is bounds-checked. Messages arrive from another process, so a
/// truncated or malformed body must produce a named error rather than a crash.
public struct DBusUnmarshaller {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case truncated(needed: Int, available: Int, at: Int)
        case invalidBoolean(UInt32)
        case invalidUTF8(at: Int)
        case unsupportedType(Character)

        public var description: String {
            switch self {
            case let .truncated(needed, available, at):
                return "D-Bus message truncated: needed \(needed) bytes at offset \(at), \(available) available."
            case let .invalidBoolean(raw):
                return "D-Bus boolean must be 0 or 1, got \(raw)."
            case let .invalidUTF8(at):
                return "Invalid UTF-8 in a D-Bus string at offset \(at)."
            case let .unsupportedType(character):
                return "Unsupported D-Bus type '\(character)'."
            }
        }
    }

    private let bytes: [UInt8]
    public private(set) var offset: Int

    public init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    public var remaining: Int { bytes.count - offset }

    public mutating func align(to alignment: Int) throws {
        guard alignment > 1 else { return }
        let remainder = offset % alignment
        guard remainder != 0 else { return }
        let padding = alignment - remainder
        guard offset + padding <= bytes.count else {
            throw Failure.truncated(needed: padding, available: bytes.count - offset, at: offset)
        }
        offset += padding
    }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard offset + count <= bytes.count else {
            throw Failure.truncated(needed: count, available: bytes.count - offset, at: offset)
        }
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }

    public mutating func readByte() throws -> UInt8 { try take(1).first! }

    public mutating func readUInt16() throws -> UInt16 {
        try align(to: 2)
        return try take(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }
    }

    public mutating func readUInt32() throws -> UInt32 {
        try align(to: 4)
        return try take(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }

    public mutating func readUInt64() throws -> UInt64 {
        try align(to: 8)
        return try take(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
    }

    public mutating func readString() throws -> String {
        let length = Int(try readUInt32())
        let raw = try take(length)
        _ = try take(1)   // trailing NUL
        guard let text = String(bytes: raw, encoding: .utf8) else {
            throw Failure.invalidUTF8(at: offset)
        }
        return text
    }

    public mutating func readSignature() throws -> String {
        let length = Int(try readByte())
        let raw = try take(length)
        _ = try take(1)
        guard let text = String(bytes: raw, encoding: .utf8) else {
            throw Failure.invalidUTF8(at: offset)
        }
        return text
    }

    /// Reads one value of the given complete type.
    public mutating func read(signature: String) throws -> DBusValue {
        guard let first = signature.first else { throw Failure.unsupportedType(" ") }
        switch first {
        case "y": return .byte(try readByte())
        case "b":
            let raw = try readUInt32()
            guard raw <= 1 else { throw Failure.invalidBoolean(raw) }
            return .boolean(raw == 1)
        case "n": return .int16(Int16(bitPattern: try readUInt16()))
        case "q": return .uint16(try readUInt16())
        case "i": return .int32(Int32(bitPattern: try readUInt32()))
        case "u": return .uint32(try readUInt32())
        case "h": return .unixFD(try readUInt32())
        case "x": return .int64(Int64(bitPattern: try readUInt64()))
        case "t": return .uint64(try readUInt64())
        case "d": return .double(Double(bitPattern: try readUInt64()))
        case "s": return .string(try readString())
        case "o": return .objectPath(try readString())
        case "g": return .signature(try readSignature())

        case "a":
            let element = String(signature.dropFirst())
            let byteLength = Int(try readUInt32())
            try align(to: DBusSignature.alignment(of: element))
            let end = offset + byteLength
            guard end <= bytes.count else {
                throw Failure.truncated(needed: byteLength, available: bytes.count - offset, at: offset)
            }
            // A byte array is the display hot path — QEMU delivers whole
            // framebuffers this way — so it is taken as raw bytes rather than
            // decoded into one boxed value per byte.
            if element == "y" {
                return .byteArray(Array(try take(byteLength)))
            }
            var values: [DBusValue] = []
            while offset < end { values.append(try read(signature: element)) }
            return .array(element: element, values: values)

        case "(":
            try align(to: 8)
            let inner = String(signature.dropFirst().dropLast())
            var members: [DBusValue] = []
            for member in try DBusSignature.split(inner) {
                members.append(try read(signature: member))
            }
            return .structure(members)

        case "{":
            try align(to: 8)
            let inner = try DBusSignature.split(String(signature.dropFirst().dropLast()))
            let key = try read(signature: inner[0])
            let value = try read(signature: inner[1])
            return .dictEntry(key: key, value: value)

        case "v":
            let inner = try readSignature()
            return .variant(try read(signature: inner))

        default:
            throw Failure.unsupportedType(first)
        }
    }

    /// Reads a whole message body described by `signature`.
    public mutating func readBody(signature: String) throws -> [DBusValue] {
        try DBusSignature.split(signature).map { try read(signature: $0) }
    }
}
