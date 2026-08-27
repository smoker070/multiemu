import CoreGraphics
import Foundation
import Metal
import Testing
@testable import MultiemuGraphics

@Suite("Display scaling geometry")
struct DisplayScalingTests {

    private func rect(_ guest: CGSize, _ surface: CGSize, _ scaling: GuestDisplayScaling) -> CGRect {
        GuestDisplayRenderer.destinationRect(guestSize: guest, surfaceSize: surface, scaling: scaling)
    }

    @Test("A 1:1 surface fills the whole viewport")
    func exactFit() {
        let result = rect(CGSize(width: 1920, height: 1080), CGSize(width: 1920, height: 1080), .aspectFit)
        #expect(abs(result.width - 2) < 1e-6)
        #expect(abs(result.height - 2) < 1e-6)
        #expect(abs(result.origin.x + 1) < 1e-6)
    }

    @Test("A wider surface pillarboxes, preserving guest aspect ratio")
    func pillarbox() {
        // 16:9 guest in a 2:1 surface: full height, narrower than the surface.
        let result = rect(CGSize(width: 1920, height: 1080), CGSize(width: 2160, height: 1080), .aspectFit)
        #expect(abs(result.height - 2) < 1e-6, "height should fill")
        #expect(result.width < 2, "width should be inset")
        // Centred: equal bars either side.
        #expect(abs(result.origin.x + result.width / 2) < 1e-6)
        // Aspect ratio preserved in surface pixels.
        let drawnWidth = result.width / 2 * 2160
        let drawnHeight = result.height / 2 * 1080
        #expect(abs(drawnWidth / drawnHeight - 1920.0 / 1080.0) < 1e-6)
    }

    @Test("A taller surface letterboxes")
    func letterbox() {
        let result = rect(CGSize(width: 1920, height: 1080), CGSize(width: 1920, height: 1440), .aspectFit)
        #expect(abs(result.width - 2) < 1e-6)
        #expect(result.height < 2)
        #expect(abs(result.origin.y + result.height / 2) < 1e-6)
    }

    @Test("Stretch ignores aspect ratio and fills")
    func stretch() {
        let result = rect(CGSize(width: 1920, height: 1080), CGSize(width: 800, height: 800), .stretch)
        #expect(result == CGRect(x: -1, y: -1, width: 2, height: 2))
    }

    @Test("Aspect fill covers the surface, overflowing on one axis")
    func aspectFill() {
        let result = rect(CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1080), .aspectFill)
        #expect(result.width > 2 || abs(result.width - 2) < 1e-6)
        #expect(abs(result.height - 2) < 1e-6 || result.height > 2)
    }

    @Test("Integer scaling snaps to a whole-number multiple")
    func integerScaling() {
        // A 640×480 guest in a 1500×1200 surface fits 2.34×, so it snaps to 2×.
        let result = rect(CGSize(width: 640, height: 480), CGSize(width: 1500, height: 1200), .integerScale)
        let drawnWidth = result.width / 2 * 1500
        #expect(abs(drawnWidth - 1280) < 1e-6, "expected exactly 2× of 640")
    }

    @Test("Integer scaling never scales below 1×, so a large guest still shows")
    func integerScalingFloor() {
        let result = rect(CGSize(width: 1920, height: 1080), CGSize(width: 800, height: 600), .integerScale)
        #expect(result.width > 0 && result.height > 0)
    }

    @Test("Degenerate sizes fall back to filling rather than dividing by zero")
    func degenerateSizes() {
        #expect(rect(.zero, CGSize(width: 100, height: 100), .aspectFit) == CGRect(x: -1, y: -1, width: 2, height: 2))
        #expect(rect(CGSize(width: 100, height: 100), .zero, .aspectFit) == CGRect(x: -1, y: -1, width: 2, height: 2))
    }

    @Test("The guest's logical resolution is independent of the surface size")
    func resolutionIndependence() {
        // The product requirement: resizing the window must not change what the
        // guest thinks its resolution is, only how it is fitted.
        let guest = CGSize(width: 1920, height: 1080)
        for surface in [CGSize(width: 640, height: 480),
                        CGSize(width: 1920, height: 1080),
                        CGSize(width: 3840, height: 2160),
                        CGSize(width: 1000, height: 3000)] {
            let result = rect(guest, surface, .aspectFit)
            let drawnWidth = result.width / 2 * surface.width
            let drawnHeight = result.height / 2 * surface.height
            #expect(abs(drawnWidth / drawnHeight - 16.0 / 9.0) < 1e-4,
                    "aspect ratio drifted at surface \(surface)")
        }
    }
}

@Suite("Metal presentation")
struct MetalPresentationTests {

    /// BGRA bytes for a colour, matching QEMU's x8r8g8b8 memory order.
    private static func bgrx(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] { [b, g, r, 0] }

    /// A frame with four distinctly coloured quadrants, so orientation errors
    /// are unmistakable rather than plausible.
    private func quadrantFrame(width: Int, height: Int) -> GuestFrame {
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let top = row < height / 2
                let left = column < width / 2
                let colour: [UInt8]
                switch (top, left) {
                case (true, true): colour = Self.bgrx(255, 0, 0)     // top-left red
                case (true, false): colour = Self.bgrx(0, 255, 0)    // top-right green
                case (false, true): colour = Self.bgrx(0, 0, 255)    // bottom-left blue
                case (false, false): colour = Self.bgrx(255, 255, 0) // bottom-right yellow
                }
                pixels.append(contentsOf: colour)
            }
        }
        return GuestFrame(width: width, height: height, stride: width * 4,
                          format: PixmanFormat(rawValue: 0x2002_0888), pixels: pixels)
    }

    private func pixel(_ frame: GuestFrame, _ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        let offset = y * frame.stride + x * 4
        return (frame.pixels[offset], frame.pixels[offset + 1], frame.pixels[offset + 2], frame.pixels[offset + 3])
    }

    @Test("A renderer initialises against the system Metal device")
    func rendererInitialises() throws {
        let renderer = try GuestDisplayRenderer()
        #expect(renderer.guestSize == .zero)
    }

    @Test("A 1:1 render reproduces the guest frame pixel for pixel")
    func exactReproduction() throws {
        let renderer = try GuestDisplayRenderer()
        let frame = quadrantFrame(width: 64, height: 64)
        try renderer.upload(frame)
        #expect(renderer.guestSize == CGSize(width: 64, height: 64))

        let target = try renderer.renderOffscreen(width: 64, height: 64, scaling: .aspectFit, smooth: false)
        let result = target.readBackAsFrame()
        #expect(result.width == 64 && result.height == 64)

        // Orientation: the guest's top-left must land in the target's top-left.
        #expect(pixel(result, 10, 10).r == 255, "top-left should be red")
        #expect(pixel(result, 54, 10).g == 255, "top-right should be green")
        #expect(pixel(result, 10, 54).b == 255, "bottom-left should be blue")
        let bottomRight = pixel(result, 54, 54)
        #expect(bottomRight.r == 255 && bottomRight.g == 255, "bottom-right should be yellow")
    }

    @Test("Alpha is forced opaque, so an x8 padding byte is never transparency")
    func alphaIsOpaque() throws {
        let renderer = try GuestDisplayRenderer()
        // Every source pixel has a zero padding byte, as QEMU sends.
        try renderer.upload(quadrantFrame(width: 32, height: 32))
        let result = try renderer.renderOffscreen(width: 32, height: 32, smooth: false).readBackAsFrame()
        for (x, y) in [(5, 5), (25, 5), (5, 25), (25, 25)] {
            #expect(pixel(result, x, y).a == 255, "pixel (\(x),\(y)) is not opaque")
        }
    }

    @Test("Pillarboxing leaves background bars and centres the image")
    func pillarboxRendering() throws {
        let renderer = try GuestDisplayRenderer()
        try renderer.upload(quadrantFrame(width: 64, height: 64))

        // A square guest in a 2:1 surface: quarter-width bars either side.
        let result = try renderer.renderOffscreen(width: 256, height: 128, smooth: false).readBackAsFrame()
        // Bars.
        for x in [2, 20, 235, 253] {
            let sample = pixel(result, x, 64)
            #expect(sample.r == 0 && sample.g == 0 && sample.b == 0,
                    "expected a background bar at x=\(x), got \(sample)")
        }
        // Image region: 128 wide, centred, so x 64..191.
        #expect(pixel(result, 80, 30).r == 255, "top-left quadrant should be red")
        #expect(pixel(result, 175, 30).g == 255, "top-right quadrant should be green")
        #expect(pixel(result, 80, 100).b == 255, "bottom-left quadrant should be blue")
    }

    @Test("A guest resolution change reallocates the texture")
    func resolutionChange() throws {
        // QEMU reports mode changes as a new Scanout with new dimensions, so
        // this happens routinely rather than exceptionally.
        let renderer = try GuestDisplayRenderer()
        try renderer.upload(quadrantFrame(width: 64, height: 48))
        #expect(renderer.guestSize == CGSize(width: 64, height: 48))
        try renderer.upload(quadrantFrame(width: 1920, height: 1080))
        #expect(renderer.guestSize == CGSize(width: 1920, height: 1080))

        let result = try renderer.renderOffscreen(width: 1920, height: 1080, smooth: false).readBackAsFrame()
        #expect(pixel(result, 100, 100).r == 255)
    }

    @Test("A frame with padded rows renders correctly")
    func strideHandling() throws {
        // Stride is not always width × 4; ignoring it skews the image
        // progressively, which looks like a shear rather than an error.
        let renderer = try GuestDisplayRenderer()
        let width = 60, height = 40, stride = 64 * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)
        for row in 0..<height {
            for column in 0..<width {
                let offset = row * stride + column * 4
                let colour = row < height / 2 ? Self.bgrx(255, 0, 0) : Self.bgrx(0, 0, 255)
                pixels.replaceSubrange(offset..<(offset + 4), with: colour)
            }
        }
        try renderer.upload(GuestFrame(width: width, height: height, stride: stride,
                                       format: PixmanFormat(rawValue: 0x2002_0888), pixels: pixels))
        let result = try renderer.renderOffscreen(width: width, height: height, smooth: false).readBackAsFrame()
        #expect(pixel(result, 30, 5).r == 255, "top half should be red")
        #expect(pixel(result, 30, 35).b == 255, "bottom half should be blue")
    }

    @Test("An unsupported pixel format is refused rather than mis-rendered")
    func unsupportedFormat() throws {
        let renderer = try GuestDisplayRenderer()
        let frame = GuestFrame(width: 8, height: 8, stride: 16,
                               format: PixmanFormat(rawValue: 0x1001_5565),   // r5g6b5
                               pixels: [UInt8](repeating: 0, count: 128))
        #expect(throws: GuestDisplayRenderer.Failure.self) { try renderer.upload(frame) }
    }

    @Test("A frame shorter than its geometry is refused")
    func truncatedFrame() throws {
        let renderer = try GuestDisplayRenderer()
        let frame = GuestFrame(width: 64, height: 64, stride: 256,
                               format: PixmanFormat(rawValue: 0x2002_0888),
                               pixels: [UInt8](repeating: 0, count: 100))
        #expect(throws: GuestDisplayRenderer.Failure.self) { try renderer.upload(frame) }
    }

    @Test("A rendered frame can be written as a PNG, which is the screenshot path")
    func screenshotPath() throws {
        let renderer = try GuestDisplayRenderer()
        try renderer.upload(quadrantFrame(width: 128, height: 96))
        let captured = try renderer.renderOffscreen(width: 256, height: 192, smooth: false).readBackAsFrame()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("multiemu-metal-\(UUID().uuidString).png")
        try captured.writePNG(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        #expect(size > 0)
        #expect(captured.nonBlackFraction() > 0.9, "the capture is mostly background")
    }

    @Test("Fullscreen on any display shape keeps the guest's aspect ratio")
    func fullscreenPreservesAspectRatio() {
        // Fullscreen is just an extreme surface shape. The guest's proportions
        // must survive it, on a very wide display and a very tall one alike.
        let guest = CGSize(width: 1920, height: 1080)
        let guestAspect = guest.width / guest.height

        for surface in [CGSize(width: 5120, height: 1440),   // ultrawide
                        CGSize(width: 3024, height: 1964),   // a laptop panel
                        CGSize(width: 1440, height: 2560)] { // rotated monitor
            let rect = GuestDisplayRenderer.destinationRect(
                guestSize: guest, surfaceSize: surface, scaling: .aspectFit)

            // The rect is in normalised device coordinates spanning -1...1, so
            // its aspect has to be scaled back by the surface's own aspect.
            let drawnAspect = (rect.width / rect.height)
                * (surface.width / surface.height)
            #expect(abs(drawnAspect - guestAspect) < 0.001,
                    "aspect not preserved on \(surface)")

            // And it must fit inside the surface rather than overflow it.
            #expect(rect.width <= 2.0 + 0.001)
            #expect(rect.height <= 2.0 + 0.001)
        }
    }
}
