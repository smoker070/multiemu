import Darwin
import Foundation
import MultiemuSupport

/// Types at the shell Android starts on `androidboot.console`, and reads what
/// comes back.
///
/// The opposite direction from `GuestConsoleResponder`: there the host answers
/// a protocol the guest speaks, here the host drives a shell the guest offers.
/// It exists because a few things can only be configured from inside the guest
/// — Android's policy routing for ADB, and stopping services that cannot work
/// on this host — and there is no other channel into a stock image.
///
/// **This is a root shell.** Everything sent here runs as root inside the
/// guest, so it takes commands this project composes and never text from the
/// guest, a downloaded file, or a user field. Treat it as the security
/// boundary it is, and keep the vocabulary small enough to read at a glance.
///
/// Synchronous and blocking by design, like `ADBClient`. Callers must run it
/// off the cooperative thread pool — looping a blocking call inside a `Task`
/// starves the executor, which has already cost this project one harness that
/// died mid-measurement with no report.
public struct GuestConsoleShell: Sendable {

    public enum Failure: Error, CustomStringConvertible {
        case socketPathTooLong(path: String, limit: Int)
        case notListening(path: String)
        case wrote(String)

        public var description: String {
            switch self {
            case let .socketPathTooLong(path, limit):
                return "The console socket path is \(path.utf8.count) bytes; the limit is \(limit): \(path)"
            case let .notListening(path):
                return "Nothing is listening on the guest console socket \(path)"
            case let .wrote(detail):
                return "Could not write to the guest console: \(detail)"
            }
        }
    }

    /// Darwin's `sockaddr_un.sun_path` capacity.
    public static let socketPathLimit = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Opens the console, hands the session to `body`, and closes it after.
    ///
    /// Scoped rather than long-lived because QEMU's socket chardev takes one
    /// client at a time: a session left open locks every other user of the
    /// port out, including the next call from this same process.
    public func withSession<T>(
        timeout: Duration = .seconds(10),
        _ body: (Session) throws -> T
    ) throws -> T {
        guard socketPath.utf8.count < Self.socketPathLimit else {
            throw Failure.socketPathTooLong(path: socketPath, limit: Self.socketPathLimit)
        }
        guard let descriptor = Self.open(path: socketPath, timeout: timeout) else {
            throw Failure.notListening(path: socketPath)
        }
        let session = Session(descriptor: descriptor)
        defer { session.close() }
        session.settle()
        return try body(session)
    }

    private static func open(path: String, timeout: Duration) -> Int32? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            if let descriptor = openOnce(path: path) { return descriptor }
            Thread.sleep(forTimeInterval: 0.1)
        } while ContinuousClock.now < deadline
        return nil
    }

    private static func openOnce(path: String) -> Int32? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        // A guest that closes the port mid-command must not kill the host
        // process, which an unhandled SIGPIPE from `send` would do.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.utf8CString.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
        let joined = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if joined == 0 { return descriptor }
        Darwin.close(descriptor)
        return nil   // QEMU is not listening yet; the caller retries.
    }

    /// One open conversation with the guest's console shell.
    public final class Session {

        /// The guest builds this from pieces, so it cannot match the echo of
        /// the command that asked for it.
        ///
        /// The console echoes everything typed. A reply marker that appears
        /// literally in the command matches its own echo first, and the caller
        /// reads back the question instead of the answer.
        private static let markerCommand = "printf 'M%s:' Q; "
        private static let marker = "MQ:"

        private let descriptor: Int32

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        /// Clears whatever the console had already printed, so the first reply
        /// is not read out of a backlog of boot messages.
        func settle() {
            _ = send("\n")
            Thread.sleep(forTimeInterval: 0.8)
            drain()
        }

        func close() {
            Darwin.close(descriptor)
        }

        /// Runs a command and returns everything the console printed, echo
        /// included. For commands whose output does not matter.
        @discardableResult
        public func run(_ command: String, settleFor: Duration = .milliseconds(1200)) -> String {
            _ = send(command + "\n")
            Thread.sleep(forTimeInterval: settleFor.seconds)
            return read(for: .milliseconds(400))
        }

        /// Runs a command and returns its first line of output, without the
        /// echo. `nil` when the guest printed no marked reply.
        public func value(of command: String, within: Duration = .seconds(6)) -> String? {
            _ = send(Self.markerCommand + command + "\n")
            let text = read(for: within)
            for line in text.split(whereSeparator: \.isNewline) {
                guard let range = line.range(of: Self.marker) else { continue }
                let tail = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty { return tail }
            }
            return nil
        }

        private func send(_ text: String) -> Bool {
            var bytes = Array(text.utf8)
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBytes {
                    Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }

        /// Reads until the console has been quiet for a moment, or `limit`
        /// expires. Quiet-based rather than a fixed sleep, because a shell
        /// reply and a burst of kernel logging arrive on the same port and
        /// there is no length to read ahead.
        private func read(for limit: Duration) -> String {
            var buffer = Data()
            var scratch = [UInt8](repeating: 0, count: 8192)
            let deadline = ContinuousClock.now.advanced(by: limit)
            var lastByteAt = ContinuousClock.now
            while ContinuousClock.now < deadline {
                let count = recv(descriptor, &scratch, scratch.count, 0)
                if count > 0 {
                    buffer.append(contentsOf: scratch[0..<count])
                    lastByteAt = ContinuousClock.now
                    continue
                }
                if count == 0 { break }   // the guest closed the port
                if !buffer.isEmpty, lastByteAt.duration(to: .now) > .milliseconds(400) { break }
            }
            return String(decoding: buffer, as: UTF8.self)
        }

        private func drain() {
            _ = read(for: .milliseconds(600))
        }
    }
}
