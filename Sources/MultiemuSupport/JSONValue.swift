import Foundation

/// A `Sendable`, `Codable` representation of arbitrary JSON.
///
/// QMP replies and events are schema-free JSON. `JSONSerialization` would give
/// us `[String: Any]`, which cannot cross an actor boundary under Swift 6 strict
/// concurrency. This enum keeps the whole control plane `Sendable` without
/// pretending we know QEMU's reply shapes ahead of time.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not valid JSON"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: Convenience accessors

    public subscript(key: String) -> JSONValue? {
        if case .object(let dictionary) = self { return dictionary[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

extension JSONValue: CustomStringConvertible {
    /// Compact JSON-like rendering.
    ///
    /// The synthesised `String(describing:)` prints Swift case syntax
    /// (`MultiemuSupport.JSONValue.bool(false)`), which is unreadable in a log
    /// line and useless in a diagnostics bundle. Control-plane payloads are
    /// rendered as the JSON they came from instead.
    public var description: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            return value == value.rounded() && abs(value) < 1e15
                ? String(Int(value))
                : String(value)
        case .string(let value): return "\"\(value)\""
        case .array(let values):
            return "[" + values.map(\.description).joined(separator: ",") + "]"
        case .object(let values):
            return "{" + values.sorted { $0.key < $1.key }
                .map { "\"\($0.key)\":\($0.value.description)" }
                .joined(separator: ",") + "}"
        }
    }
}
