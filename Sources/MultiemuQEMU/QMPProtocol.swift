import Foundation
import MultiemuSupport

/// The QEMU Machine Protocol message layer.
///
/// Deliberately separated from the socket so it can be tested exhaustively
/// without QEMU installed: QMP framing is newline-delimited JSON, and every
/// interesting behaviour (greeting, capability negotiation, success, error,
/// asynchronous events arriving interleaved with replies) is expressible as a
/// string.
public enum QMPProtocol {

    /// The banner QEMU sends immediately on connect, before it will accept
    /// commands.
    public struct Greeting: Sendable, Equatable {
        public var qemuVersion: String
        public var capabilities: [String]

        public init(qemuVersion: String, capabilities: [String]) {
            self.qemuVersion = qemuVersion
            self.capabilities = capabilities
        }
    }

    /// An asynchronous event, e.g. `SHUTDOWN`, `RESET`, `GUEST_PANICKED`.
    public struct Event: Sendable, Equatable {
        public var name: String
        public var data: JSONValue?
        public var timestampSeconds: Double?

        public init(name: String, data: JSONValue?, timestampSeconds: Double?) {
            self.name = name
            self.data = data
            self.timestampSeconds = timestampSeconds
        }
    }

    /// One decoded line from the socket.
    public enum Message: Sendable, Equatable {
        case greeting(Greeting)
        case success(JSONValue)
        case failure(errorClass: String, description: String)
        case event(Event)
    }

    public enum DecodingFailure: Error, Sendable, Equatable {
        case notJSON(String)
        case unrecognisedShape(String)
    }

    /// Decodes a single newline-delimited QMP line.
    public static func decode(line: String) throws -> Message {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DecodingFailure.notJSON(line) }

        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)),
              case .object = value else {
            throw DecodingFailure.notJSON(trimmed)
        }

        if let qmp = value["QMP"] {
            let version = qmp["version"]?["qemu"].map { qemu in
                let major = qemu["major"]?.intValue ?? 0
                let minor = qemu["minor"]?.intValue ?? 0
                let micro = qemu["micro"]?.intValue ?? 0
                return "\(major).\(minor).\(micro)"
            } ?? "unknown"

            var capabilities: [String] = []
            if case .array(let items)? = qmp["capabilities"] {
                capabilities = items.compactMap(\.stringValue)
            }
            return .greeting(Greeting(qemuVersion: version, capabilities: capabilities))
        }

        if let error = value["error"] {
            return .failure(
                errorClass: error["class"]?.stringValue ?? "GenericError",
                description: error["desc"]?.stringValue ?? "no description"
            )
        }

        if let eventName = value["event"]?.stringValue {
            var timestamp: Double?
            if let stamp = value["timestamp"], case .number(let seconds)? = stamp["seconds"] {
                let microseconds: Double
                if case .number(let value)? = stamp["microseconds"] { microseconds = value } else { microseconds = 0 }
                timestamp = seconds + microseconds / 1_000_000
            }
            return .event(Event(name: eventName, data: value["data"], timestampSeconds: timestamp))
        }

        if let result = value["return"] {
            return .success(result)
        }

        throw DecodingFailure.unrecognisedShape(trimmed)
    }

    /// Encodes a command as a single line, newline included.
    ///
    /// Argument values are `JSONValue`, so nothing that reaches this function
    /// can inject raw text into the protocol stream.
    public static func encode(command: String, arguments: [String: JSONValue] = [:]) throws -> Data {
        var object: [String: JSONValue] = ["execute": .string(command)]
        if !arguments.isEmpty {
            object["arguments"] = .object(arguments)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(JSONValue.object(object))
        data.append(0x0A)
        return data
    }
}
