import Foundation

/// A D-Bus value.
///
/// Only the subset QEMU's display interfaces actually use is modelled. Adding a
/// type means adding it to the marshaller, the unmarshaller and the signature
/// parser together, so an unmodelled type fails loudly rather than being
/// silently mis-decoded.
public indirect enum DBusValue: Sendable, Equatable {
    case byte(UInt8)
    case boolean(Bool)
    case int16(Int16)
    case uint16(UInt16)
    case int32(Int32)
    case uint32(UInt32)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case string(String)
    case objectPath(String)
    case signature(String)
    /// An index into the message's attached file descriptors, not a descriptor.
    case unixFD(UInt32)
    /// `element` is the element signature, needed to marshal an empty array.
    case array(element: String, values: [DBusValue])
    /// An `ay` array held as raw bytes.
    ///
    /// A dedicated case rather than `array(element: "y", …)` because this is the
    /// display hot path: a 1280×800 frame is 4 MiB, and representing it as four
    /// million boxed enum values costs orders of magnitude more time and memory
    /// than the frame itself. Both spellings decode through `byteArrayValue`.
    case byteArray([UInt8])
    case structure([DBusValue])
    case variant(DBusValue)
    case dictEntry(key: DBusValue, value: DBusValue)

    /// The D-Bus signature of this value.
    public var signature: String {
        switch self {
        case .byte: return "y"
        case .boolean: return "b"
        case .int16: return "n"
        case .uint16: return "q"
        case .int32: return "i"
        case .uint32: return "u"
        case .int64: return "x"
        case .uint64: return "t"
        case .double: return "d"
        case .string: return "s"
        case .objectPath: return "o"
        case .signature: return "g"
        case .unixFD: return "h"
        case .array(let element, _): return "a" + element
        case .byteArray: return "ay"
        case .structure(let members): return "(" + members.map(\.signature).joined() + ")"
        case .variant: return "v"
        case .dictEntry(let key, let value): return "{" + key.signature + value.signature + "}"
        }
    }

    // MARK: Convenience accessors

    public var uint32Value: UInt32? {
        if case .uint32(let value) = self { return value }
        return nil
    }

    public var int32Value: Int32? {
        if case .int32(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .boolean(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        switch self {
        case .string(let value), .objectPath(let value), .signature(let value): return value
        default: return nil
        }
    }

    /// Bytes of an `ay` array, which is how QEMU delivers pixels.
    ///
    /// Accepts either representation so callers never have to care which one
    /// produced the value.
    public var byteArrayValue: [UInt8]? {
        switch self {
        case .byteArray(let bytes):
            return bytes
        case .array(let element, let values) where element == "y":
            return values.compactMap { if case .byte(let byte) = $0 { return byte } else { return nil } }
        default:
            return nil
        }
    }
}

/// Splits a signature into its top-level complete types.
///
/// `"uuay"` → `["u", "u", "ay"]`; `"a(ii)s"` → `["a(ii)", "s"]`. Needed because
/// a message body is a sequence of values whose boundaries are only discoverable
/// by parsing the signature.
public enum DBusSignature {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unterminated(String)
        case unexpectedCharacter(Character, in: String)

        public var description: String {
            switch self {
            case let .unterminated(signature): return "Unterminated D-Bus signature \"\(signature)\"."
            case let .unexpectedCharacter(character, signature):
                return "Unexpected character '\(character)' in D-Bus signature \"\(signature)\"."
            }
        }
    }

    public static func split(_ signature: String) throws -> [String] {
        var result: [String] = []
        let characters = Array(signature)
        var index = 0
        while index < characters.count {
            let start = index
            try consumeOne(characters, &index, signature)
            result.append(String(characters[start..<index]))
        }
        return result
    }

    private static func consumeOne(_ characters: [Character], _ index: inout Int, _ signature: String) throws {
        guard index < characters.count else { throw Failure.unterminated(signature) }
        let character = characters[index]
        switch character {
        case "y", "b", "n", "q", "i", "u", "x", "t", "d", "s", "o", "g", "v", "h":
            index += 1
        case "a":
            index += 1
            try consumeOne(characters, &index, signature)
        case "(":
            index += 1
            while index < characters.count, characters[index] != ")" {
                try consumeOne(characters, &index, signature)
            }
            guard index < characters.count else { throw Failure.unterminated(signature) }
            index += 1   // past ')'
        case "{":
            index += 1
            while index < characters.count, characters[index] != "}" {
                try consumeOne(characters, &index, signature)
            }
            guard index < characters.count else { throw Failure.unterminated(signature) }
            index += 1   // past '}'
        default:
            throw Failure.unexpectedCharacter(character, in: signature)
        }
    }

    /// Alignment in bytes required before a value of this type.
    ///
    /// These are fixed by the specification, and getting one wrong corrupts
    /// every value after it in the message rather than failing cleanly.
    public static func alignment(of signature: String) -> Int {
        guard let first = signature.first else { return 1 }
        switch first {
        case "y", "g", "v": return 1
        case "n", "q": return 2
        case "b", "i", "u", "s", "o", "a", "h": return 4
        case "x", "t", "d", "(", "{": return 8
        default: return 1
        }
    }
}
