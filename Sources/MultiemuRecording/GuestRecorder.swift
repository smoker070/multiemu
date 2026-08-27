import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import MultiemuGraphics
import MultiemuSupport

/// Records the guest display to a video file.
///
/// The design point that matters is what recording is *not* allowed to do: it
/// must not slow the interactive frame path. So `submit(_:)` only stores the
/// most recent frame under a lock — no encoding, no allocation — and the encode
/// happens on the recorder's own cadence. A guest that renders faster than the
/// recording rate simply has frames dropped; one that renders slower has the
/// last frame held.
///
/// That cadence also gives the file a real, stated frame rate rather than
/// whatever irregular timing the guest happened to produce.
public final class GuestRecorder: @unchecked Sendable {

    public struct Configuration: Sendable {
        public var url: URL
        /// Fixed for the whole recording. A file cannot change dimensions
        /// mid-stream, and the guest can change resolution at any time
        /// (Milestone 12), so differing frames are fitted into this instead.
        public var width: Int
        public var height: Int
        public var framesPerSecond: Int
        public var codec: AVVideoCodecType

        public init(
            url: URL,
            width: Int,
            height: Int,
            framesPerSecond: Int = 30,
            codec: AVVideoCodecType = .h264
        ) {
            // Encoders reject odd dimensions, and the guest can legitimately
            // produce them, so round rather than fail at the first frame.
            self.url = url
            self.width = max(2, width - (width % 2))
            self.height = max(2, height - (height % 2))
            self.framesPerSecond = max(1, framesPerSecond)
            self.codec = codec
        }
    }

    public struct Summary: Sendable, Equatable {
        public var url: URL
        public var width: Int
        public var height: Int
        public var framesPerSecond: Int
        /// Frames written to the file, including any held while the guest was
        /// still — a constant-rate file has one per tick by definition.
        public var framesWritten: Int
        /// Frames the guest produced that were never written, because it
        /// rendered faster than the recording rate.
        public var framesDropped: Int
        /// Frames written by holding the previous one, because the guest
        /// rendered slower than the recording rate.
        public var framesHeld: Int
        /// Ticks the encoder could not accept even after waiting. A constant
        /// rate file should have none; any at all mean the file's timing has
        /// drifted from real time.
        public var ticksSkipped: Int
        /// Ticks that had to wait for the encoder, and how long in total. A
        /// tick that waits longer than its own interval halves the effective
        /// frame rate, because the next one is coalesced.
        public var ticksWaited: Int = 0
        public var totalWaitSeconds: Double = 0
        /// Ticks lost to a failure rather than to the encoder being busy: no
        /// pixel buffer, a copy that failed, or an append the writer rejected.
        /// Counted rather than returned silently, because a silent drop looks
        /// exactly like a slow timer.
        public var ticksFailed: Int = 0
        /// Ticks that found no frame at all, before the guest had drawn one.
        public var ticksWithoutAFrame: Int = 0
        /// How often the cadence actually fired, and how long the handler took.
        /// A handler slower than its own interval halves the effective rate,
        /// because Dispatch coalesces the tick it overran.
        public var timerTicks: Int = 0
        public var slowestHandlerSeconds: Double = 0
        public var averageHandlerSeconds: Double = 0
        public var fileSizeBytes: UInt64
        /// How long the recording ran in real time. Filled in by
        /// `RecordingSession`, so the file's own duration can be compared
        /// against the clock rather than assumed to match it.
        public var wallClockSeconds: Double = 0

        public var duration: Duration {
            .milliseconds(framesWritten * 1000 / max(1, framesPerSecond))
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case alreadyRecording
        case notRecording
        case writerRefused(String)
        case noPixelBufferPool

        public var description: String {
            switch self {
            case .alreadyRecording: return "A recording is already in progress."
            case .notRecording: return "No recording is in progress."
            case let .writerRefused(detail): return "The video writer refused the recording: \(detail)"
            case .noPixelBufferPool: return "The video writer provided no pixel buffer pool."
            }
        }
    }

    public let configuration: Configuration

    private let lock = NSLock()
    private var pendingFrame: GuestFrame?
    private var pendingIsNew = false

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?

    private var frameIndex = 0
    private var dropped = 0
    private var held = 0
    private var skipped = 0
    private var waited = 0
    private var waitSeconds = 0.0
    private var failed = 0
    private var starved = 0
    private var isRecording = false

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - Lifecycle

    public func start() throws {
        guard !isRecording else { throw Failure.alreadyRecording }
        try? FileManager.default.removeItem(at: configuration.url)
        try FileManager.default.createDirectory(
            at: configuration.url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let writer = try AVAssetWriter(outputURL: configuration.url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: configuration.codec,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
        ])
        // The frames arrive from a live guest, so the encoder is told not to
        // wait for a complete picture of the timeline before emitting.
        input.expectsMediaDataInRealTime = true

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: configuration.width,
                kCVPixelBufferHeightKey as String: configuration.height,
            ])
        guard writer.canAdd(input) else {
            throw Failure.writerRefused("the video track was rejected")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw Failure.writerRefused(writer.error.map(String.init(describing:)) ?? "unknown reason")
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        frameIndex = 0
        dropped = 0
        held = 0
        skipped = 0
        waited = 0
        waitSeconds = 0
        failed = 0
        starved = 0
        isRecording = true

        MultiemuLog.graphics.info("""
            Recording \(self.configuration.width, privacy: .public)×\
            \(self.configuration.height, privacy: .public) at \
            \(self.configuration.framesPerSecond, privacy: .public) fps
            """)
    }

    /// Records the newest frame. Called from the frame path, so it does as
    /// little as possible: take a lock, store, return.
    public func submit(_ frame: GuestFrame) {
        lock.lock()
        defer { lock.unlock() }
        // A frame arriving before the next tick replaces the one waiting: the
        // guest outran the recording rate and the older frame is never written.
        if pendingIsNew { dropped += 1 }
        pendingFrame = frame
        pendingIsNew = true
    }

    /// Writes one frame at the recording's own cadence.
    ///
    /// Separate from any timer so a test can drive it deterministically instead
    /// of waiting on wall-clock time.
    @discardableResult
    public func writeTick() -> Bool {
        guard isRecording, let adaptor, let input else { return false }

        lock.lock()
        let frame = pendingFrame
        let wasNew = pendingIsNew
        pendingIsNew = false
        lock.unlock()

        // Nothing has ever arrived: there is no picture to write yet.
        guard let frame else { starved += 1; return false }
        if !wasNew { held += 1 }

        // Wait briefly for the encoder, rather than skipping the tick.
        //
        // This is safe precisely because `writeTick` runs on the recorder's own
        // cadence and never on the frame path — the interactive display is not
        // waiting on it. Appending measures 0.28 ms against a 33 ms tick at
        // 30 fps, so this should never actually sleep; without it a burst can
        // silently shorten the file and drift its timing from real time.
        if !input.isReadyForMoreMediaData {
            let waitStarted = Date()
            let deadline = waitStarted.addingTimeInterval(
                min(1.0 / Double(configuration.framesPerSecond), 0.05))
            while !input.isReadyForMoreMediaData, Date() < deadline {
                usleep(200)
            }
            waited += 1
            waitSeconds += Date().timeIntervalSince(waitStarted)
        }
        guard input.isReadyForMoreMediaData else {
            skipped += 1
            return false
        }
        guard let pool = adaptor.pixelBufferPool else { failed += 1; return false }

        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else { failed += 1; return false }

        guard copy(frame, into: buffer) else { failed += 1; return false }

        let time = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(configuration.framesPerSecond))
        guard adaptor.append(buffer, withPresentationTime: time) else { failed += 1; return false }
        frameIndex += 1
        return true
    }

    public func finish() async throws -> Summary {
        guard isRecording, let writer, let input else { throw Failure.notRecording }
        isRecording = false
        input.markAsFinished()
        await writer.finishWriting()

        if writer.status == .failed {
            throw Failure.writerRefused(writer.error.map(String.init(describing:)) ?? "unknown reason")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: configuration.url.path)[.size]) as? UInt64

        self.writer = nil
        self.input = nil
        self.adaptor = nil
        clearPendingFrame()

        return Summary(
            url: configuration.url,
            width: configuration.width,
            height: configuration.height,
            framesPerSecond: configuration.framesPerSecond,
            framesWritten: frameIndex,
            framesDropped: dropped,
            framesHeld: held,
            ticksSkipped: skipped,
            ticksWaited: waited,
            totalWaitSeconds: waitSeconds,
            ticksFailed: failed,
            ticksWithoutAFrame: starved,
            fileSizeBytes: size ?? 0
        )
    }

    /// Scoped so it is callable from an async context, where holding an
    /// `NSLock` across a suspension would be unsound.
    private func clearPendingFrame() {
        lock.withLock {
            pendingFrame = nil
            pendingIsNew = false
        }
    }

    // MARK: - Pixels

    /// Copies a guest frame into a pixel buffer, fitting it if the guest's
    /// resolution is not the one being recorded.
    private func copy(_ frame: GuestFrame, into buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let destinationStride = CVPixelBufferGetBytesPerRow(buffer)

        // `isSupported` is the same gate `makeImage` applies, checked here too
        // so an unrecognised layout is never memcpy'd straight into a video.
        if frame.format.isSupported,
           frame.width == configuration.width, frame.height == configuration.height {
            // The guest's layout is byteOrder32Little/skipFirst, which is the
            // same bytes as 32BGRA — the ignored byte is ignored by the encoder
            // too, since it converts to YUV. So this is a straight row copy.
            let rowBytes = min(frame.width * 4, destinationStride)
            frame.pixels.withUnsafeBytes { source in
                guard let base = source.baseAddress else { return }
                for row in 0..<frame.height {
                    memcpy(destination.advanced(by: row * destinationStride),
                           base.advanced(by: row * frame.stride),
                           rowBytes)
                }
            }
            return true
        }

        // The guest changed resolution mid-recording, which Milestone 12 makes
        // an ordinary thing to do. The file cannot change size, so the frame is
        // fitted into it — letterboxed, aspect preserved — rather than the
        // recording failing or the picture stretching.
        guard let image = try? frame.makeImage() else { return false }
        var bitmapInfo = CGBitmapInfo.byteOrder32Little
        bitmapInfo.insert(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
        guard let context = CGContext(
            data: destination,
            width: configuration.width,
            height: configuration.height,
            bitsPerComponent: 8,
            bytesPerRow: destinationStride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ) else { return false }

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: configuration.width, height: configuration.height))

        let scale = min(Double(configuration.width) / Double(frame.width),
                        Double(configuration.height) / Double(frame.height))
        let drawWidth = Double(frame.width) * scale
        let drawHeight = Double(frame.height) * scale
        context.draw(image, in: CGRect(
            x: (Double(configuration.width) - drawWidth) / 2,
            y: (Double(configuration.height) - drawHeight) / 2,
            width: drawWidth, height: drawHeight))
        return true
    }
}
