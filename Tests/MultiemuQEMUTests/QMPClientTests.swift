import Darwin
import Foundation
import MultiemuSupport
import Testing
@testable import MultiemuQEMU

/// A minimal QMP server, so the client can be tested without QEMU.
///
/// Speaks just enough of the protocol to exercise the client's real paths:
/// greeting, capability negotiation, ordered replies, error replies, and
/// asynchronous events interleaved with replies.
final class FakeQMPServer: @unchecked Sendable {
    let socketPath: String
    private var listenDescriptor: Int32 = -1
    private var thread: Thread?
    /// Extra lines pushed to the client after capability negotiation.
    private let scriptedLines: [String]
    private let failCommands: Set<String>

    init(scriptedLines: [String] = [], failCommands: Set<String> = []) {
        self.socketPath = QMPClient.makeSocketPath(role: "test")
        self.scriptedLines = scriptedLines
        self.failCommands = failCommands
    }

    func start() throws {
        unlink(socketPath)
        listenDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(listenDescriptor >= 0)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            socketPath.utf8CString.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)
        #expect(listen(listenDescriptor, 1) == 0)

        let listener = listenDescriptor
        let scripted = scriptedLines
        let failing = failCommands
        let thread = Thread {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            func send(_ line: String) {
                let payload = Array((line + "\n").utf8)
                _ = payload.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
            }

            send(#"{"QMP": {"version": {"qemu": {"major": 11, "minor": 1, "micro": 0}}, "capabilities": ["oob"]}}"#)

            var buffer = [UInt8](repeating: 0, count: 4096)
            var pending = Data()
            var negotiated = false
            while true {
                let count = read(connection, &buffer, buffer.count)
                guard count > 0 else { break }
                pending.append(contentsOf: buffer[0..<count])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let lineData = pending[pending.startIndex..<newline]
                    pending.removeSubrange(pending.startIndex...newline)
                    let line = String(decoding: lineData, as: UTF8.self)

                    let command = (try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)))?["execute"]?.stringValue ?? ""
                    if failing.contains(command) {
                        send(#"{"error": {"class": "GenericError", "desc": "command '"# + command + #"' rejected"}}"#)
                    } else if command == "query-status" {
                        send(#"{"return": {"running": true, "status": "running"}}"#)
                    } else {
                        send(#"{"return": {}}"#)
                    }

                    if command == "qmp_capabilities", !negotiated {
                        negotiated = true
                        for scriptedLine in scripted { send(scriptedLine) }
                    }
                }
            }
            close(connection)
        }
        thread.name = "fake.qmp.server"
        thread.start()
        self.thread = thread
    }

    func stop() {
        if listenDescriptor >= 0 { close(listenDescriptor) }
        unlink(socketPath)
    }
}

@Suite("QMP client", .serialized)
struct QMPClientTests {

    @Test("Connect performs the greeting and capability handshake")
    func handshake() async throws {
        let server = FakeQMPServer()
        try server.start()
        defer { server.stop() }

        let client = QMPClient()
        let greeting = try await client.connect(toSocketAt: server.socketPath, timeout: .seconds(5))
        #expect(greeting.qemuVersion == "11.1.0")
        #expect(greeting.capabilities == ["oob"])
        await client.disconnect()
    }

    @Test("Commands receive their matching reply")
    func commandReply() async throws {
        let server = FakeQMPServer()
        try server.start()
        defer { server.stop() }

        let client = QMPClient()
        try await client.connect(toSocketAt: server.socketPath, timeout: .seconds(5))
        let status = try await client.queryStatus()
        #expect(status == "running")
        await client.disconnect()
    }

    @Test("Replies stay matched to commands when events interleave")
    func eventsDoNotDesynchroniseReplies() async throws {
        // The failure this guards against is subtle and catastrophic: if an
        // asynchronous event were counted as a reply, every later command would
        // receive the previous command's answer.
        let server = FakeQMPServer(scriptedLines: [
            #"{"event": "RESUME"}"#,
            #"{"event": "NIC_RX_FILTER_CHANGED", "data": {"name": "net0"}}"#,
        ])
        try server.start()
        defer { server.stop() }

        let client = QMPClient()
        try await client.connect(toSocketAt: server.socketPath, timeout: .seconds(5))
        for _ in 0..<10 {
            #expect(try await client.queryStatus() == "running")
        }
        await client.disconnect()
    }

    @Test("Asynchronous events are delivered on the event stream")
    func eventsAreDelivered() async throws {
        let server = FakeQMPServer(scriptedLines: [
            #"{"event": "POWERDOWN"}"#,
            #"{"event": "SHUTDOWN", "data": {"guest": false, "reason": "host-qmp-quit"}}"#,
        ])
        try server.start()
        defer { server.stop() }

        let client = QMPClient()
        let stream = client.events
        try await client.connect(toSocketAt: server.socketPath, timeout: .seconds(5))
        _ = try await client.queryStatus()   // ensure the scripted lines have been sent

        var received: [String] = []
        for await event in stream {
            received.append(event.name)
            if received.count == 2 { break }
        }
        #expect(received == ["POWERDOWN", "SHUTDOWN"])
        await client.disconnect()
    }

    @Test("An error reply surfaces as a thrown commandFailed")
    func errorReply() async throws {
        let server = FakeQMPServer(failCommands: ["screendump"])
        try server.start()
        defer { server.stop() }

        let client = QMPClient()
        try await client.connect(toSocketAt: server.socketPath, timeout: .seconds(5))
        await #expect(throws: QMPClient.Failure.self) {
            try await client.execute("screendump", arguments: ["filename": .string("/tmp/x.ppm")])
        }
        // The channel must remain usable after a rejected command.
        #expect(try await client.queryStatus() == "running")
        await client.disconnect()
    }

    @Test("Connecting to a path that is too long fails with a named error")
    func socketPathTooLong() async {
        // sockaddr_un.sun_path is 104 bytes on Darwin. Ordinary project paths
        // exceed it, which is why control sockets never live beside the device.
        let tooLong = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
        let client = QMPClient()
        await #expect(throws: QMPClient.Failure.socketPathTooLong(tooLong, limit: QMPClient.socketPathLimit)) {
            try await client.connect(toSocketAt: tooLong, timeout: .milliseconds(100))
        }
    }

    @Test("Generated socket paths fit within the platform limit")
    func generatedPathsFit() {
        for role in ["qmp", "console", "gpu", "guest-agent"] {
            let path = QMPClient.makeSocketPath(role: role)
            #expect(path.utf8.count < QMPClient.socketPathLimit,
                    "\(path) is \(path.utf8.count) bytes, limit \(QMPClient.socketPathLimit)")
        }
    }

    @Test("Connecting where nothing listens times out with a named error")
    func connectTimeout() async {
        let client = QMPClient()
        await #expect(throws: QMPClient.Failure.self) {
            try await client.connect(
                toSocketAt: QMPClient.makeSocketPath(role: "absent"),
                timeout: .milliseconds(200)
            )
        }
    }
}

extension QMPClient.Failure {
    /// Convenience for the path-too-long expectation.
    static func socketPathTooLong(_ path: String, limit: Int) -> QMPClient.Failure {
        .socketPathTooLong(path: path, limit: limit)
    }
}
