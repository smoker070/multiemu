import Foundation
import Testing
@testable import MultiemuRecording
import MultiemuGraphics

/// The milestone's constraint is that recording must not drop the interactive
/// frame rate below 30 FPS. Recording touches the interactive path in exactly
/// one place — `submit(_:)` — so that is the quantity worth guarding.
///
/// The encode itself happens on the recorder's own cadence and is measured
/// separately; it cannot slow the display because the display never waits on it.
@Suite("Recording performance")
struct RecordingPerformanceTests {

    private func frame(width: Int, height: Int) -> GuestFrame {
        GuestFrame(
            width: width, height: height, stride: width * 4,
            format: PixmanFormat(rawValue: 0x2002_8888),
            pixels: [UInt8](repeating: 0x80, count: width * height * 4))
    }

    @Test("Submitting a 1080p frame is a negligible part of a 30 fps budget")
    func submitIsCheap() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("multiemu-submit-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = GuestRecorder(configuration: .init(
            url: url, width: 1920, height: 1080, framesPerSecond: 30))
        try recorder.start()

        let picture = frame(width: 1920, height: 1080)
        var timings: [Double] = []
        for _ in 0..<600 {
            let started = DispatchTime.now().uptimeNanoseconds
            recorder.submit(picture)
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }

        let sorted = timings.sorted()
        let median = sorted[sorted.count / 2]
        let p99 = sorted[Int(Double(sorted.count) * 0.99)]
        print("  submit 1080p: median \(String(format: "%.4f", median)) ms, p99 \(String(format: "%.4f", p99)) ms")

        // 33.3 ms is one frame at 30 fps. Submitting must be a rounding error
        // against it, or recording would be stealing the display's budget.
        //
        // The median is held tight because that is the property. The tail is
        // deliberately loose: this ran on a shared machine, and a scheduler
        // hiccup in one sample of 600 is not the frame path being slow. A
        // tighter bound here failed once during a compatibility run and passed
        // every time it was repeated, which is worse than useless — a claim
        // that fails at random teaches people to ignore the matrix.
        #expect(median < 1.0)
        #expect(p99 < 10.0)

        _ = recorder   // keep alive until measurement completes
    }

    @Test("The encode keeps ahead of a 30 fps cadence at 1080p")
    func encodeKeepsUp() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("multiemu-encode-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = GuestRecorder(configuration: .init(
            url: url, width: 1920, height: 1080, framesPerSecond: 30))
        try recorder.start()
        let picture = frame(width: 1920, height: 1080)

        var timings: [Double] = []
        for _ in 0..<90 {
            recorder.submit(picture)
            let started = DispatchTime.now().uptimeNanoseconds
            recorder.writeTick()
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        let summary = try await recorder.finish()

        let sorted = timings.sorted()
        let median = sorted[sorted.count / 2]
        print("  encode tick 1080p: median \(String(format: "%.2f", median)) ms of a 33.3 ms budget")

        #expect(summary.framesWritten >= 88)
        // The property is that the encode keeps ahead of the cadence, not that
        // it never hiccups once under arbitrary machine load. A couple of
        // skipped ticks out of ninety is noise; a systematic backlog is not.
        #expect(summary.ticksSkipped <= 2)
        #expect(median < 33.3)
    }
}
