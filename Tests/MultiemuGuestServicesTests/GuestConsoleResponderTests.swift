import Darwin
import Foundation
import Testing
@testable import MultiemuGuestServices

/// Stands in for QEMU: listens on a UNIX socket, accepts one connection, and
/// lets a test push bytes at the responder and read what comes back.
///
/// A real socket rather than a seam, because the parts most likely to be wrong
/// — partial reads, short writes, the peer closing — only exist at this level.
private final class FakeQEMUChardev: @unchecked Sendable {

    let path: String
    private let listener: Int32
    private var connection: Int32 = -1

    init() throws {
        // Short, because sockaddr_un.sun_path is 104 bytes and a test bundle's
        // working directory is not.
        let name = "mm-test-\(UUID().uuidString.prefix(8)).sock"
        path = (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
        unlink(path)

        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.utf8CString.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw Failure.bindFailed(errno) }
        guard listen(listener, 1) == 0 else { throw Failure.listenFailed(errno) }
    }

    enum Failure: Error { case bindFailed(Int32), listenFailed(Int32), acceptFailed }

    func acceptConnection() throws {
        let accepted = accept(listener, nil, nil)
        guard accepted >= 0 else { throw Failure.acceptFailed }
        // So a test cannot hang forever on a reply that never comes.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(accepted, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        connection = accepted
    }

    func send(_ data: Data) {
        _ = data.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
    }

    /// Reads until `count` bytes arrive or the socket times out.
    func receive(_ count: Int) -> Data {
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while collected.count < count {
            let read = Darwin.read(connection, &buffer, min(buffer.count, count - collected.count))
            guard read > 0 else { break }
            collected.append(contentsOf: buffer[0..<read])
        }
        return collected
    }

    func closeConnection() {
        if connection >= 0 { close(connection); connection = -1 }
    }

    func tearDown() {
        closeConnection()
        close(listener)
        unlink(path)
    }
}

@Suite("Guest console responder")
struct GuestConsoleResponderTests {

    private func request(_ command: String, type: UInt32 = 0) -> Data {
        QemudFrame.encode(type: type, payload: Data(command.utf8))
    }

    private func decodeOne(_ data: Data) throws -> QemudFrame.Message? {
        var decoder = QemudDecoder()
        return try decoder.ingest(data).first
    }

    @Test("A request over a real socket is answered in the same framing")
    func answersOverASocket() async throws {
        let chardev = try FakeQEMUChardev()
        defer { chardev.tearDown() }

        let responder = GuestConsoleResponder(socketPath: chardev.path, service: SensorsService())
        try await responder.start()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try chardev.acceptConnection() })
            }
        }

        chardev.send(request("list-sensors"))
        let reply = try #require(try decodeOne(chardev.receive(9)))
        #expect(reply.command == "0")
        await responder.stop()
    }

    @Test("The reply carries back the type the guest sent")
    func preservesMessageType() async throws {
        let chardev = try FakeQEMUChardev()
        defer { chardev.tearDown() }

        let responder = GuestConsoleResponder(socketPath: chardev.path, service: SensorsService())
        try await responder.start()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try chardev.acceptConnection() })
            }
        }

        chardev.send(request("list-sensors", type: 42))
        let reply = try #require(try decodeOne(chardev.receive(9)))
        #expect(reply.type == 42)
        await responder.stop()
    }

    @Test("A request arriving in fragments is still answered once")
    func answersAFragmentedRequest() async throws {
        let chardev = try FakeQEMUChardev()
        defer { chardev.tearDown() }

        let responder = GuestConsoleResponder(socketPath: chardev.path, service: SensorsService())
        try await responder.start()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try chardev.acceptConnection() })
            }
        }

        let whole = request("list-sensors")
        for byte in whole {
            chardev.send(Data([byte]))
        }
        let reply = try #require(try decodeOne(chardev.receive(9)))
        #expect(reply.command == "0")
        await responder.stop()
    }

    @Test("Several queued requests are each answered, in order")
    func answersSeveralRequests() async throws {
        let chardev = try FakeQEMUChardev()
        defer { chardev.tearDown() }

        let responder = GuestConsoleResponder(socketPath: chardev.path, service: SensorsService())
        try await responder.start()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try chardev.acceptConnection() })
            }
        }

        // Only list-sensors and wake are answered; configuration commands are
        // deliberately silent, so three requests yield two replies.
        chardev.send(request("list-sensors") + request("set-delay:200") + request("wake"))
        var decoder = QemudDecoder()
        let replies = try decoder.ingest(chardev.receive(9 + 12))
        #expect(replies.map(\.command) == ["0", "wake"])
        #expect(await responder.repliesSent == 2)
        await responder.stop()
    }

    @Test("A guest-declared length beyond the cap drops the connection instead of allocating")
    func oversizedLengthDropsTheConnection() async throws {
        let chardev = try FakeQEMUChardev()
        defer { chardev.tearDown() }

        let responder = GuestConsoleResponder(socketPath: chardev.path, service: SensorsService())
        try await responder.start()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try chardev.acceptConnection() })
            }
        }

        // A header claiming 4 GiB, with nothing behind it.
        var hostile = Data()
        withUnsafeBytes(of: UInt32(0).littleEndian) { hostile.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32.max.littleEndian) { hostile.append(contentsOf: $0) }
        chardev.send(hostile)

        // The responder must hang up rather than answer or wait for 4 GiB.
        #expect(chardev.receive(1).isEmpty, "nothing should be sent in reply to a refused frame")

        var settled = false
        for _ in 0..<50 where !settled {
            if await responder.faultsSeen > 0 { settled = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(settled, "the fault should have been counted")
        await responder.stop()
    }


    // MARK: Regressions from the adversarial review

    @Test("A guest that closes the port with a request unanswered does not kill this process")
    func peerClosingMidRequestIsSurvivable() async throws {
        let chardev = try FakeQEMUChardev()
        defer { chardev.tearDown() }

        let responder = GuestConsoleResponder(socketPath: chardev.path, service: SensorsService())
        try await responder.start()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try chardev.acceptConnection() })
            }
        }

        // Queue requests, then vanish. The reply lands on a socket with no
        // reader; without SO_NOSIGPIPE that raises SIGPIPE, which is fatal by
        // default and would take the whole emulator down with it.
        for _ in 0..<200 { chardev.send(request("list-sensors")) }
        chardev.closeConnection()

        // Reaching here at all is the assertion: a SIGPIPE would have killed
        // the test process outright.
        try? await Task.sleep(for: .milliseconds(300))
        await responder.stop()
        #expect(Bool(true), "survived a peer that closed mid-reply")
    }

    @Test("A large burst of well-formed frames is answered without loss")
    func largeBurstIsAnsweredWithoutLoss() async throws {
        let chardev = try FakeQEMUChardev()
        defer { chardev.tearDown() }

        let responder = GuestConsoleResponder(socketPath: chardev.path, service: SensorsService())
        try await responder.start()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try chardev.acceptConnection() })
            }
        }

        // Real commands, because an unanswered command produces no reply to
        // count. This exercises volume, not malformedness.
        //
        // Sending and draining must overlap. The responder reads and replies in
        // sequence on one thread — deliberately, so a guest cannot queue bytes
        // ahead of the decoder — which means a test that sends everything
        // before reading anything deadlocks against its own socket buffers.
        // That deadlock is the backpressure working.
        let frames = 2000
        let draining = Task.detached { chardev.receive(9 * frames) }

        var burst = Data()
        for _ in 0..<frames { burst += request("list-sensors") }
        let payload = burst
        await Task.detached { chardev.send(payload) }.value

        var decoder = QemudDecoder()
        let replies = try decoder.ingest(await draining.value)
        #expect(replies.count == frames, "every frame should be answered exactly once")
        #expect(replies.allSatisfy { $0.command == "0" })
        await responder.stop()
    }

    @Test("A responder that has actually spent its fault budget can be started again")
    func startWorksAfterSpendingTheBudget() async throws {
        let chardev = try FakeQEMUChardev()
        defer { chardev.tearDown() }

        let responder = GuestConsoleResponder(socketPath: chardev.path, service: SensorsService())
        try await responder.start()

        // Genuinely spend the budget. The previous version of this test only
        // called stop() and start() — it never sent a bad frame, so it passed
        // without exercising the thing it was named for, which is worse than
        // having no test at all.
        var hostile = Data()
        withUnsafeBytes(of: UInt32(0).littleEndian) { hostile.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32.max.littleEndian) { hostile.append(contentsOf: $0) }

        for _ in 0..<GuestConsoleResponder.faultBudget {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                DispatchQueue.global().async {
                    c.resume(with: Result { try chardev.acceptConnection() })
                }
            }
            chardev.send(hostile)
            var settled = false
            for _ in 0..<60 where !settled {
                if await responder.isServing == false { settled = true; break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            chardev.closeConnection()
            if await responder.faultsSeen >= GuestConsoleResponder.faultBudget { break }
        }

        #expect(await responder.faultsSeen >= 1, "the budget should have been spent")
        await responder.stop()

        // A fresh start must clear the budget, or the port stays dead for the
        // life of the process while start() still reports success.
        try await responder.start()
        #expect(await responder.faultsSeen == 0, "the budget is per run")
        #expect(await responder.isServing == true)
        await responder.stop()
    }

    @Test("A stop that overlaps a start does not leave two serve loops running")
    func overlappingStopAndStartDoNotBothRun() async throws {
        // No listener yet, so the first run parks in its connect retry loop —
        // the window in which an earlier version let start() resurrect the loop
        // stop() was still awaiting, hanging stop() forever and orphaning a
        // worker with its descriptor open.
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("mm-race-\(UUID().uuidString.prefix(8)).sock")
        let responder = GuestConsoleResponder(socketPath: path, service: SensorsService())
        try await responder.start(connectTimeout: .seconds(2))

        async let stopping: Void = responder.stop()
        try? await Task.sleep(for: .milliseconds(5))
        try await responder.start(connectTimeout: .seconds(2))
        await stopping

        // Reaching here means the stop returned rather than hanging.
        await responder.stop()
        #expect(await responder.isServing == false)
    }


    @Test("A responder that cannot connect reports it instead of failing silently")
    func reportsFailureToConnect() async throws {
        // A path nothing is listening on: the responder should give up and say
        // so, because the only other symptom is a guest that stalls with a boot
        // timeout naming nothing.
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("mm-absent-\(UUID().uuidString.prefix(8)).sock")

        let reported = ReportBox()
        let responder = GuestConsoleResponder(
            socketPath: path, service: SensorsService(),
            onHealthChange: { health in reported.record(health) })
        try await responder.start(connectTimeout: .milliseconds(300))

        var settled = false
        for _ in 0..<40 where !settled {
            if reported.first != nil { settled = true; break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        await responder.stop()
        #expect(reported.first == .couldNotConnect(path: path))
    }

    @Test("A responder reports that it is serving once connected")
    func reportsServing() async throws {
        let chardev = try FakeQEMUChardev()
        defer { chardev.tearDown() }

        let reported = ReportBox()
        let responder = GuestConsoleResponder(
            socketPath: chardev.path, service: SensorsService(),
            onHealthChange: { health in reported.record(health) })
        try await responder.start()

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global().async { c.resume(with: Result { try chardev.acceptConnection() }) }
        }
        var settled = false
        for _ in 0..<40 where !settled {
            if reported.first != nil { settled = true; break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        await responder.stop()
        #expect(reported.first == .serving)
    }


    @Test("A path too long for sockaddr_un is refused before anything is opened")
    func refusesOverlongPath() async {
        let tooLong = "/tmp/" + String(repeating: "d", count: 120) + ".sock"
        let responder = GuestConsoleResponder(socketPath: tooLong, service: SensorsService())
        await #expect(throws: GuestConsoleResponder.Failure.self) {
            try await responder.start()
        }
    }

    @Test("Stopping ends the responder without needing the peer to close")
    func stopIsEnough() async throws {
        let chardev = try FakeQEMUChardev()
        defer { chardev.tearDown() }

        let responder = GuestConsoleResponder(socketPath: chardev.path, service: SensorsService())
        try await responder.start()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try chardev.acceptConnection() })
            }
        }
        await responder.stop()
        // Starting again after a stop must be possible: a device may restart.
        try await responder.start()
        await responder.stop()
    }
}


/// Collects health reports from a responder. The observer is `@Sendable` and
/// fires from the responder's own context, so the storage needs a lock.
private final class ReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [GuestConsoleResponder.Health] = []

    func record(_ health: GuestConsoleResponder.Health) {
        lock.lock(); defer { lock.unlock() }
        reports.append(health)
    }

    var first: GuestConsoleResponder.Health? {
        lock.lock(); defer { lock.unlock() }
        return reports.first
    }
}
