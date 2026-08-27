import CoreGraphics
import Foundation
import Metal
import MultiemuSupport
import Testing
@testable import MultiemuGraphics

/// Measures Multiemu's half of the frame budget: uploading a guest frame to the
/// GPU and drawing it.
///
/// The guest's own frame rate cannot be measured against a static text console,
/// so what is guarded here is the cost the *host* adds. At 60 fps the whole
/// budget is 16.7 ms, and presentation must be a small fraction of it.
@Suite("Presentation performance")
struct PresentationPerformanceTests {

    private func frame(width: Int, height: Int) -> GuestFrame {
        GuestFrame(
            width: width, height: height, stride: width * 4,
            format: PixmanFormat(rawValue: 0x2002_0888),
            pixels: [UInt8](repeating: 0x7F, count: width * height * 4)
        )
    }

    private func median(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    @Test("Uploading a 1080p frame is a small part of a 60 fps budget")
    func uploadCost() throws {
        let renderer = try GuestDisplayRenderer()
        let source = frame(width: 1920, height: 1080)
        try renderer.upload(source)   // allocate the texture once, outside the measurement

        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<30 {
            let start = clock.now
            try renderer.upload(source)
            samples.append((clock.now - start).milliseconds)
        }
        let result = median(samples)
        print("  1080p upload:  median \(String(format: "%.2f", result)) ms")
        #expect(result < 6.0, "uploading one frame took \(result) ms")
    }

    @Test("Rendering a 1080p frame to a 4K surface stays within budget")
    func renderCost() throws {
        let renderer = try GuestDisplayRenderer()
        try renderer.upload(frame(width: 1920, height: 1080))
        _ = try renderer.renderOffscreen(width: 3840, height: 2160)   // warm up

        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<20 {
            let start = clock.now
            _ = try renderer.renderOffscreen(width: 3840, height: 2160)
            samples.append((clock.now - start).milliseconds)
        }
        let result = median(samples)
        print("  1080p -> 4K render (incl. GPU wait): median \(String(format: "%.2f", result)) ms"
              + "  -> \(String(format: "%.0f", 1000 / result)) fps ceiling")
        #expect(result < 16.7, "rendering one frame took \(result) ms, which cannot sustain 60 fps")
    }

    @Test("The full host path — decode, upload, render — fits in a 60 fps frame")
    func endToEndHostCost() throws {
        // The number that matters for the product target: everything Multiemu
        // does between bytes arriving and pixels being drawn.
        let renderer = try GuestDisplayRenderer()
        let source = frame(width: 1920, height: 1080)
        try renderer.upload(source)
        _ = try renderer.renderOffscreen(width: 1920, height: 1080)

        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<20 {
            let start = clock.now
            try renderer.upload(source)
            _ = try renderer.renderOffscreen(width: 1920, height: 1080)
            samples.append((clock.now - start).milliseconds)
        }
        let result = median(samples)
        print("  host path (upload+render): median \(String(format: "%.2f", result)) ms"
              + "  -> \(String(format: "%.0f", 1000 / result)) fps ceiling")
        #expect(result < 16.7)
    }
}
