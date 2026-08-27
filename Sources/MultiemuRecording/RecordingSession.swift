import AVFoundation
import Foundation
import MultiemuGraphics
import MultiemuSupport

/// Drives a `GuestRecorder` at a steady cadence on its own queue.
///
/// The cadence lives here, off the frame path, which is the whole reason
/// recording cannot slow the interactive display: the display thread only ever
/// calls `submit(_:)`, which takes a lock and returns.
public final class RecordingSession: @unchecked Sendable {

    private let recorder: GuestRecorder
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private let started: Date
    private let statsLock = NSLock()
    private var tickCount = 0
    private var slowestHandlerSeconds = 0.0
    private var totalHandlerSeconds = 0.0

    public var configuration: GuestRecorder.Configuration { recorder.configuration }

    public init(configuration: GuestRecorder.Configuration) {
        self.recorder = GuestRecorder(configuration: configuration)
        // `.userInitiated`, not `.utility`: recording is visible work with a
        // deadline. A background queue is scheduled onto efficiency cores and
        // its timer coalesced, which shows up as a file that plays back slower
        // than real time rather than as any kind of error.
        self.queue = DispatchQueue(label: "com.multiemu.recording", qos: .userInitiated)
        self.started = Date()
    }

    /// Starts recording, seeded with the picture already on screen.
    ///
    /// The seed is not optional in practice: the recorder is fed by *new*
    /// frames, and a guest that is not redrawing sends none. Without it a
    /// recording of a still screen produces nothing at all until the guest
    /// happens to change — which is exactly when a user would be recording a
    /// static screen to show what is on it.
    public func start(initialFrame: GuestFrame? = nil) throws {
        try recorder.start()
        if let initialFrame { recorder.submit(initialFrame) }
        let interval = 1.0 / Double(recorder.configuration.framesPerSecond)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // `.now() + interval` rather than `.now()`: the first tick would
        // otherwise fire before any frame has arrived and write nothing.
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [recorder, self] in
            let began = Date()
            recorder.writeTick()
            let took = Date().timeIntervalSince(began)
            self.statsLock.withLock {
                self.tickCount += 1
                self.totalHandlerSeconds += took
                self.slowestHandlerSeconds = max(self.slowestHandlerSeconds, took)
            }
        }
        timer.resume()
        self.timer = timer
    }

    /// Called from the frame path. Deliberately trivial.
    public func submit(_ frame: GuestFrame) {
        recorder.submit(frame)
    }

    public func stop() async throws -> GuestRecorder.Summary {
        timer?.cancel()
        timer = nil
        // Let a tick already in flight finish before the writer is torn down.
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
        var summary = try await recorder.finish()
        summary.wallClockSeconds = Date().timeIntervalSince(started)
        statsLock.withLock {
            summary.timerTicks = tickCount
            summary.slowestHandlerSeconds = slowestHandlerSeconds
            summary.averageHandlerSeconds = tickCount > 0 ? totalHandlerSeconds / Double(tickCount) : 0
        }
        return summary
    }
}
