import Foundation
import MultiemuSupport
import Testing
@testable import MultiemuQEMU

@Suite("QMP protocol")
struct QMPProtocolTests {

    @Test("The connect greeting yields the QEMU version and capabilities")
    func greeting() throws {
        let line = #"{"QMP": {"version": {"qemu": {"micro": 2, "minor": 1, "major": 10}, "package": ""}, "capabilities": ["oob"]}}"#
        guard case .greeting(let greeting) = try QMPProtocol.decode(line: line) else {
            Issue.record("expected a greeting")
            return
        }
        #expect(greeting.qemuVersion == "10.1.2")
        #expect(greeting.capabilities == ["oob"])
    }

    @Test("A successful reply is decoded")
    func successReply() throws {
        guard case .success(let value) = try QMPProtocol.decode(line: #"{"return": {"running": true, "status": "running"}}"#) else {
            Issue.record("expected success")
            return
        }
        #expect(value["status"]?.stringValue == "running")
        #expect(value["running"]?.boolValue == true)
    }

    @Test("An empty return object still decodes as success")
    func emptySuccess() throws {
        guard case .success(let value) = try QMPProtocol.decode(line: #"{"return": {}}"#) else {
            Issue.record("expected success")
            return
        }
        #expect(value == .object([:]))
    }

    @Test("An error reply carries class and description")
    func errorReply() throws {
        let line = #"{"error": {"class": "GenericError", "desc": "Device 'virtio-gpu-pci' not found"}}"#
        guard case .failure(let errorClass, let description) = try QMPProtocol.decode(line: line) else {
            Issue.record("expected failure")
            return
        }
        #expect(errorClass == "GenericError")
        #expect(description.contains("virtio-gpu-pci"))
    }

    @Test("Asynchronous events decode with a timestamp")
    func event() throws {
        let line = #"{"timestamp": {"seconds": 1700000000, "microseconds": 500000}, "event": "SHUTDOWN", "data": {"guest": true, "reason": "guest-shutdown"}}"#
        guard case .event(let event) = try QMPProtocol.decode(line: line) else {
            Issue.record("expected event")
            return
        }
        #expect(event.name == "SHUTDOWN")
        #expect(event.data?["reason"]?.stringValue == "guest-shutdown")
        #expect(event.timestampSeconds == 1_700_000_000.5)
    }

    @Test("A guest panic event is an event, not an error reply")
    func guestPanicked() throws {
        // This distinction matters: a panic arrives asynchronously and must not
        // be mistaken for the failure of whatever command happened to be pending.
        guard case .event(let event) = try QMPProtocol.decode(line: #"{"event": "GUEST_PANICKED", "data": {"action": "pause"}}"#) else {
            Issue.record("expected event")
            return
        }
        #expect(event.name == "GUEST_PANICKED")
        #expect(event.timestampSeconds == nil)
    }

    @Test("Non-JSON and unrecognised shapes throw rather than silently decoding")
    func malformedInput() {
        #expect(throws: QMPProtocol.DecodingFailure.self) { try QMPProtocol.decode(line: "not json at all") }
        #expect(throws: QMPProtocol.DecodingFailure.self) { try QMPProtocol.decode(line: "") }
        #expect(throws: QMPProtocol.DecodingFailure.self) { try QMPProtocol.decode(line: #"{"unexpected": 1}"#) }
        #expect(throws: QMPProtocol.DecodingFailure.self) { try QMPProtocol.decode(line: "[1,2,3]") }
    }

    @Test("A realistic interleaved stream decodes in order")
    func interleavedStream() throws {
        let stream = [
            #"{"QMP": {"version": {"qemu": {"major": 10, "minor": 0, "micro": 0}}, "capabilities": []}}"#,
            #"{"return": {}}"#,
            #"{"event": "RESUME"}"#,
            #"{"return": {"status": "running"}}"#,
            #"{"event": "SHUTDOWN", "data": {"guest": true}}"#,
        ]
        let messages = try stream.map { try QMPProtocol.decode(line: $0) }
        #expect(messages.count == 5)
        if case .greeting = messages[0] {} else { Issue.record("0 should be greeting") }
        if case .success = messages[1] {} else { Issue.record("1 should be success") }
        if case .event = messages[2] {} else { Issue.record("2 should be event") }
        if case .success = messages[3] {} else { Issue.record("3 should be success") }
        if case .event = messages[4] {} else { Issue.record("4 should be event") }
    }

    @Test("Commands encode as one newline-terminated JSON line")
    func encodeCommand() throws {
        let data = try QMPProtocol.encode(command: "qmp_capabilities")
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasSuffix("\n"))
        #expect(text.contains("\"execute\":\"qmp_capabilities\""))
        #expect(!text.dropLast().contains("\n"))
    }

    @Test("Command arguments are encoded as structured JSON, not interpolated text")
    func encodeCommandWithArguments() throws {
        let data = try QMPProtocol.encode(
            command: "screendump",
            arguments: ["filename": .string("/tmp/shot\".png"), "device": .string("virtio-gpu")]
        )
        let text = String(decoding: data, as: UTF8.self)
        // The embedded quote must be escaped by the JSON encoder — this is why
        // arguments are JSONValue rather than a pre-built string.
        #expect(text.contains(#"\""#))
        let reparsed = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(reparsed["arguments"]?["filename"]?.stringValue == "/tmp/shot\".png")
    }

    @Test("Round-tripping a decoded reply through JSONValue is lossless")
    func jsonValueRoundTrip() throws {
        let original = #"{"return":{"a":[1,2,{"b":null}],"c":true,"d":"x"}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(original.utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let reencoded = String(decoding: try encoder.encode(value), as: UTF8.self)
        #expect(reencoded == original)
    }
}
