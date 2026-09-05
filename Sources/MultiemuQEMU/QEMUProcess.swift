import Darwin
import Foundation
import MultiemuSupport

/// Supervises one QEMU child process and streams its console.
///
/// Not an actor: `Process` and `Pipe` are not `Sendable`, and the object is
/// owned by a single task for its whole life. Events leave through an
/// `AsyncStream` continuation, which *is* `Sendable`, so nothing non-`Sendable`
/// ever crosses a concurrency boundary.
public final class QEMUProcess {

    public enum Event: Sendable, Equatable {
        /// One line of guest serial console output.
        case consoleLine(String)
        /// One line QEMU itself wrote to stderr.
        case backendMessage(String)
        /// The process exited. `reason` distinguishes exit from signal.
        case exited(code: Int32, reason: String)
    }

    public enum StartFailure: Error, Sendable {
        case executableNotFound(path: String)
        case notExecutable(path: String)
        case launchFailed(String)
    }

    public let arguments: [String]
    public let executableURL: URL
    public private(set) var startedAt: ContinuousClock.Instant?

    private let process = Process()
    private let standardOutput = Pipe()
    private let standardError = Pipe()
    private let continuation: AsyncStream<Event>.Continuation

    /// Console and backend events, in arrival order.
    public let events: AsyncStream<Event>

    public init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
        var capturedContinuation: AsyncStream<Event>.Continuation!
        self.events = AsyncStream { capturedContinuation = $0 }
        self.continuation = capturedContinuation
    }

    public func start() throws {
        let path = executableURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw StartFailure.executableNotFound(path: path)
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw StartFailure.notExecutable(path: path)
        }

        process.executableURL = executableURL
        // Passed as an array: `Process` performs no shell interpretation, so
        // paths with spaces and any other metacharacters are safe.
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        // Every backend is spawned with `-serial stdio`, and an unset
        // standardInput hands each child the parent's own stdin. With one device
        // that is merely untidy; with several they compete for the same input.
        process.standardInput = FileHandle.nullDevice
        // A minimal environment: the child inherits nothing that could redirect
        // library loading or change its behaviour based on the developer's shell.
        process.environment = ["PATH": "/usr/bin:/bin"]

        let continuation = self.continuation
        install(pipe: standardOutput) { continuation.yield(.consoleLine($0)) }
        install(pipe: standardError) { continuation.yield(.backendMessage($0)) }

        process.terminationHandler = { finished in
            // Released before the event is published: once it is gone the pid
            // may be recycled, and signalling a recycled pid would kill an
            // unrelated process.
            OrphanReaper.release(finished.processIdentifier)
            let reason = finished.terminationReason == .uncaughtSignal ? "signal" : "exit"
            continuation.yield(.exited(code: finished.terminationStatus, reason: reason))
            continuation.finish()
        }

        do {
            try process.run()
        } catch {
            continuation.finish()
            throw StartFailure.launchFailed(String(describing: error))
        }
        startedAt = ContinuousClock().now
        // macOS reparents this child to launchd if we die first, and a QEMU
        // holding a device's qcow2 write lock makes that device unstartable
        // until someone finds it with `lsof`. See `OrphanReaper`.
        OrphanReaper.adopt(process.processIdentifier)

        MultiemuLog.backend.info("""
            Started \(self.executableURL.lastPathComponent, privacy: .public) \
            pid \(self.process.processIdentifier, privacy: .public)
            """)
    }

    public var processIdentifier: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    /// Asks QEMU to exit. `SIGTERM` first; the caller escalates if needed.
    public func requestTermination() {
        guard process.isRunning else { return }
        process.terminate()
    }

    /// Unconditionally kills the process. Used only after a graceful attempt
    /// has timed out.
    public func kill() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    public func waitUntilExit() {
        process.waitUntilExit()
    }

    /// Splits a pipe into lines and forwards them.
    ///
    /// A partial line is held until its newline arrives, so a console message
    /// never appears split across two events — boot-milestone matching depends
    /// on whole lines.
    private func install(pipe: Pipe, emit: @escaping @Sendable (String) -> Void) {
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                buffer.flush(emit)
                return
            }
            buffer.append(data, emit)
        }
    }
}

/// Accumulates bytes and emits complete lines. Thread-safe: `readabilityHandler`
/// callbacks arrive on an arbitrary queue.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    func append(_ data: Data, _ emit: @Sendable (String) -> Void) {
        var completed: [String] = []
        lock.lock()
        pending.append(data)
        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<newlineIndex]
            pending.removeSubrange(pending.startIndex...newlineIndex)
            completed.append(
                String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            )
        }
        lock.unlock()
        completed.forEach(emit)
    }

    func flush(_ emit: @Sendable (String) -> Void) {
        lock.lock()
        let remainder = pending
        pending.removeAll()
        lock.unlock()
        if !remainder.isEmpty {
            emit(String(decoding: remainder, as: UTF8.self))
        }
    }
}
