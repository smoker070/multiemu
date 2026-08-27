import AVFoundation
import Foundation
import Testing
@testable import MultiemuRecording
import MultiemuGraphics

/// Recording is verified by reading the file back with AVFoundation, not by
/// trusting that the writer reported success — a file that cannot be opened is
/// the failure this milestone is about.
@Suite("Screen recording")
struct GuestRecorderTests {

    private func makeFrame(width: Int, height: Int, seed: UInt8 = 0) -> GuestFrame {
        let stride = width * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)
        // Real content, so the encoder cannot compress an empty image to nothing
        // and hide a mistake.
        for index in stride1(from: 0, to: pixels.count, by: 4) {
            let pixel = index / 4
            pixels[index] = UInt8((pixel &+ Int(seed)) % 251)
            pixels[index + 1] = UInt8((pixel / 97 &+ Int(seed)) % 251)
            pixels[index + 2] = UInt8((pixel / 13 &+ Int(seed)) % 251)
            pixels[index + 3] = 255
        }
        return GuestFrame(
            width: width, height: height, stride: stride,
            // pixman ARGB8888: (32 bpp << 24) | (TYPE_ARGB << 16) | 8 bits each.
            format: PixmanFormat(rawValue: 0x2002_8888), pixels: pixels)
    }

    private func stride1(from: Int, to: Int, by: Int) -> StrideTo<Int> {
        Swift.stride(from: from, to: to, by: by)
    }

    private func scratchURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("multiemu-recording-\(UUID().uuidString).mov")
    }

    @Test("A recording produces a playable file at the stated resolution and rate")
    func producesPlayableFile() async throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = GuestRecorder(configuration: .init(
            url: url, width: 640, height: 360, framesPerSecond: 30))
        try recorder.start()

        let frames = 45   // 1.5 s at 30 fps
        for index in 0..<frames {
            recorder.submit(makeFrame(width: 640, height: 360, seed: UInt8(index % 200)))
            recorder.writeTick()
        }
        let summary = try await recorder.finish()

        #expect(summary.framesWritten == frames)
        #expect(summary.fileSizeBytes > 0)

        // Read it back rather than trust the summary.
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        let size = try await track.load(.naturalSize)
        #expect(Int(size.width) == 640)
        #expect(Int(size.height) == 360)

        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 1.5) < 0.1)

        let nominalRate = try await track.load(.nominalFrameRate)
        #expect(abs(nominalRate - 30) < 1.0)
    }

    @Test("Odd dimensions are rounded, because encoders reject them")
    func oddDimensionsAreRounded() {
        let configuration = GuestRecorder.Configuration(
            url: URL(fileURLWithPath: "/tmp/x.mov"), width: 1281, height: 721)
        #expect(configuration.width == 1280)
        #expect(configuration.height == 720)
    }

    @Test("A guest rendering faster than the recording rate has frames dropped, not queued")
    func fasterGuestDropsFrames() async throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = GuestRecorder(configuration: .init(
            url: url, width: 320, height: 240, framesPerSecond: 30))
        try recorder.start()

        // Three frames arrive between ticks: only the newest is ever written.
        for tick in 0..<10 {
            for sub in 0..<3 {
                recorder.submit(makeFrame(width: 320, height: 240, seed: UInt8(tick * 3 + sub)))
            }
            recorder.writeTick()
        }
        let summary = try await recorder.finish()

        #expect(summary.framesWritten == 10)
        // Two of every three are superseded before the tick.
        #expect(summary.framesDropped == 20)
        #expect(summary.framesHeld == 0)
    }

    @Test("A still guest has its last frame held, so the file keeps a constant rate")
    func stillGuestHoldsFrames() async throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = GuestRecorder(configuration: .init(
            url: url, width: 320, height: 240, framesPerSecond: 30))
        try recorder.start()

        recorder.submit(makeFrame(width: 320, height: 240))
        for _ in 0..<15 { recorder.writeTick() }
        let summary = try await recorder.finish()

        // Every tick is accounted for: it either wrote a frame or was skipped
        // because the encoder was not ready. Asserting `framesWritten == 15`
        // outright made this test fail on a loaded machine — `writeTick` waits
        // at most min(1/fps, 50 ms) for the encoder and then counts a skip, by
        // design, so an exact count is a property of host speed rather than of
        // the recorder. That flakiness reached the generated compatibility
        // matrix and recorded a working capability as FAIL.
        #expect(summary.framesWritten + summary.ticksSkipped == 15)
        #expect(summary.framesDropped == 0)
        #expect(summary.framesWritten >= 1)

        // Only one frame was ever submitted, so every written frame except at
        // most one is a hold. "At most" and not "exactly": the same
        // encoder-not-ready skip that the count above allows for can land on
        // the very tick that would have written the new frame, and the frame is
        // then consumed rather than carried forward — after which every
        // remaining tick holds, and `framesHeld == framesWritten`.
        //
        // Observed on a loaded machine as 14 held against 14 written, failing
        // an `== framesWritten - 1` that had looked exact. This is the second
        // timing assumption in this one test to reach the generated
        // compatibility matrix as a FAIL for a capability that works.
        #expect(summary.framesHeld == summary.framesWritten
                || summary.framesHeld == summary.framesWritten - 1)
        #expect(summary.framesHeld >= summary.framesWritten - 1)
    }

    @Test("A resolution change mid-recording is fitted, not fatal")
    func resolutionChangeIsFitted() async throws {
        // Milestone 12 makes changing resolution an ordinary runtime action, and
        // a video file cannot change dimensions — so the recording has to cope.
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = GuestRecorder(configuration: .init(
            url: url, width: 640, height: 360, framesPerSecond: 30))
        try recorder.start()

        for _ in 0..<10 {
            recorder.submit(makeFrame(width: 640, height: 360))
            recorder.writeTick()
        }
        // The guest rotates: portrait frames into a landscape file.
        for _ in 0..<10 {
            recorder.submit(makeFrame(width: 360, height: 640))
            recorder.writeTick()
        }
        let summary = try await recorder.finish()

        #expect(summary.framesWritten == 20)

        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        // One size throughout, as a file must have.
        #expect(Int(size.width) == 640)
        #expect(Int(size.height) == 360)
    }

    @Test("A recording of a still guest is not empty")
    func stillGuestStillRecords() async throws {
        // The recorder is fed by NEW frames, and a guest that is not redrawing
        // sends none — so without seeding, recording a static screen produced a
        // file with nothing in it until the guest happened to change. Which is
        // exactly the case where someone records a still screen to show what is
        // on it.
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let session = RecordingSession(configuration: .init(
            url: url, width: 320, height: 240, framesPerSecond: 30))
        try session.start(initialFrame: makeFrame(width: 320, height: 240))

        // Nothing is submitted after this point: the guest is perfectly still.
        try await Task.sleep(for: .milliseconds(500))
        let summary = try await session.stop()

        #expect(summary.framesWritten > 5, "a still guest recorded nothing")
        #expect(summary.ticksWithoutAFrame == 0)
        #expect(summary.framesHeld == summary.framesWritten - 1)
    }

    @Test("A tick before any frame arrives writes nothing")
    func tickBeforeFirstFrameWritesNothing() async throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = GuestRecorder(configuration: .init(
            url: url, width: 320, height: 240, framesPerSecond: 30))
        try recorder.start()
        #expect(!recorder.writeTick())

        recorder.submit(makeFrame(width: 320, height: 240))
        #expect(recorder.writeTick())
        _ = try await recorder.finish()
    }

    @Test("Starting twice, or finishing without starting, is refused by name")
    func lifecycleIsGuarded() async throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = GuestRecorder(configuration: .init(
            url: url, width: 320, height: 240, framesPerSecond: 30))
        try recorder.start()
        #expect(throws: GuestRecorder.Failure.self) { try recorder.start() }
        recorder.submit(makeFrame(width: 320, height: 240))
        recorder.writeTick()
        _ = try await recorder.finish()

        await #expect(throws: GuestRecorder.Failure.self) { _ = try await recorder.finish() }
    }
}
