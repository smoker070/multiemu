import CoreGraphics
import Foundation
import MultiemuGraphics
import Testing
@testable import MultiemuInput

@Suite("Pointer coordinate mapping")
struct PointerCoordinateMapperTests {

    private let guest = CGSize(width: 1920, height: 1080)

    private func locate(
        _ point: CGPoint,
        view: CGSize,
        scale: CGFloat = 1,
        guestSize: CGSize? = nil,
        scaling: GuestDisplayScaling = .aspectFit,
        flipped: Bool = true
    ) -> PointerCoordinateMapper.Location {
        PointerCoordinateMapper.locate(
            viewPoint: point, viewSize: view, backingScale: scale,
            guestSize: guestSize ?? guest, scaling: scaling, flipped: flipped
        )
    }

    private func inside(_ location: PointerCoordinateMapper.Location) -> CGPoint? {
        if case .inside(let point) = location { return point }
        return nil
    }

    @Test("A 1:1 view maps points straight through")
    func exactMapping() throws {
        let view = CGSize(width: 1920, height: 1080)
        let centre = try #require(inside(locate(CGPoint(x: 960, y: 540), view: view)))
        #expect(abs(centre.x - 960) < 0.5)
        #expect(abs(centre.y - 540) < 0.5)
    }

    @Test("The view's corners map to the guest's corners")
    func corners() throws {
        let view = CGSize(width: 1920, height: 1080)
        let topLeft = try #require(inside(locate(CGPoint(x: 0, y: 0), view: view)))
        #expect(topLeft == CGPoint(x: 0, y: 0))

        // The last addressable pixel is width-1, so a click on the far edge must
        // not produce a coordinate one past the framebuffer.
        let bottomRight = try #require(inside(locate(CGPoint(x: 1919.9, y: 1079.9), view: view)))
        #expect(bottomRight.x <= guest.width - 1)
        #expect(bottomRight.y <= guest.height - 1)
    }

    @Test("A bottom-left origin view is flipped to the guest's top-left origin")
    func originFlip() throws {
        // AppKit views are bottom-left by default; the guest framebuffer is
        // top-left. Getting this wrong inverts every click vertically.
        let view = CGSize(width: 1920, height: 1080)
        let unflipped = try #require(inside(locate(CGPoint(x: 100, y: 100), view: view, flipped: false)))
        #expect(abs(unflipped.y - 979) < 1.5, "a click near the view's bottom should be near the guest's bottom")

        let flipped = try #require(inside(locate(CGPoint(x: 100, y: 100), view: view, flipped: true)))
        #expect(abs(flipped.y - 100) < 1.5)
    }

    @Test("Clicks in the pillarbox are reported as outside")
    func pillarboxIsOutside() {
        // A 16:9 guest in a 2:1 view leaves bars either side.
        let view = CGSize(width: 2160, height: 1080)
        if case .outside = locate(CGPoint(x: 10, y: 540), view: view) {} else {
            Issue.record("a click in the left bar should be outside the guest image")
        }
        if case .outside = locate(CGPoint(x: 2150, y: 540), view: view) {} else {
            Issue.record("a click in the right bar should be outside the guest image")
        }
        #expect(inside(locate(CGPoint(x: 1080, y: 540), view: view)) != nil,
                "the centre should be inside")
    }

    @Test("Clicks in the letterbox are reported as outside")
    func letterboxIsOutside() {
        let view = CGSize(width: 1920, height: 1440)
        if case .outside = locate(CGPoint(x: 960, y: 10), view: view) {} else {
            Issue.record("a click in the top bar should be outside")
        }
        #expect(inside(locate(CGPoint(x: 960, y: 720), view: view)) != nil)
    }

    @Test("The centre of the view is the centre of the guest at every size")
    func centreIsStable() throws {
        for view in [CGSize(width: 640, height: 480), CGSize(width: 1920, height: 1080),
                     CGSize(width: 900, height: 620), CGSize(width: 3000, height: 1000)] {
            let centre = try #require(inside(locate(
                CGPoint(x: view.width / 2, y: view.height / 2), view: view
            )), "centre was outside at view \(view)")
            #expect(abs(centre.x - guest.width / 2) < 1, "x drifted at \(view)")
            #expect(abs(centre.y - guest.height / 2) < 1, "y drifted at \(view)")
        }
    }

    @Test("HiDPI does not change where a view point lands")
    func hidpiIsTransparentToTheCaller() throws {
        // Both the view point and the surface scale together, so the guest
        // coordinate must be identical at 1× and 2×.
        let view = CGSize(width: 900, height: 620)
        let point = CGPoint(x: 321, y: 222)
        let atOne = try #require(inside(locate(point, view: view, scale: 1)))
        let atTwo = try #require(inside(locate(point, view: view, scale: 2)))
        #expect(abs(atOne.x - atTwo.x) < 0.001)
        #expect(abs(atOne.y - atTwo.y) < 0.001)
    }

    @Test("Guest pixels round-trip through the presentation geometry")
    func roundTripAgainstTheRenderer() throws {
        // The strongest check available: take a guest pixel, work out where the
        // renderer would draw it, and confirm the mapper sends a click there
        // back to the same pixel.
        let view = CGSize(width: 900, height: 620)
        let scale: CGFloat = 2
        let surface = CGSize(width: view.width * scale, height: view.height * scale)
        let ndc = GuestDisplayRenderer.destinationRect(
            guestSize: guest, surfaceSize: surface, scaling: .aspectFit
        )
        let imageX = (ndc.origin.x + 1) / 2 * surface.width
        let imageWidth = ndc.size.width / 2 * surface.width
        let imageTop = (1 - (ndc.origin.y + ndc.size.height)) / 2 * surface.height
        let imageHeight = ndc.size.height / 2 * surface.height

        for guestPoint in [CGPoint(x: 0, y: 0), CGPoint(x: 960, y: 540),
                           CGPoint(x: 1919, y: 1079), CGPoint(x: 100, y: 900)] {
            // Where the renderer draws this guest pixel, in view points.
            let pixelX = imageX + (guestPoint.x + 0.5) / guest.width * imageWidth
            let pixelY = imageTop + (guestPoint.y + 0.5) / guest.height * imageHeight
            let viewPoint = CGPoint(x: pixelX / scale, y: pixelY / scale)

            let mapped = try #require(inside(locate(viewPoint, view: view, scale: scale)))
            #expect(abs(mapped.x - guestPoint.x) < 1.0, "x round-trip failed for \(guestPoint)")
            #expect(abs(mapped.y - guestPoint.y) < 1.0, "y round-trip failed for \(guestPoint)")
        }
    }

    @Test("Stretch scaling has no outside region")
    func stretchCoversEverything() {
        let view = CGSize(width: 3000, height: 400)
        for point in [CGPoint(x: 1, y: 1), CGPoint(x: 2999, y: 399), CGPoint(x: 1500, y: 200)] {
            #expect(inside(locate(point, view: view, scaling: .stretch)) != nil,
                    "\(point) should be inside under stretch")
        }
    }

    @Test("Clamping keeps a drag tracking at the edge instead of dropping it")
    func clampedForDrags() {
        let view = CGSize(width: 2160, height: 1080)
        let clamped = PointerCoordinateMapper.clampedGuestPoint(
            viewPoint: CGPoint(x: -500, y: -500), viewSize: view, backingScale: 1,
            guestSize: guest, scaling: .aspectFit, flipped: true
        )
        #expect(clamped.x >= 0 && clamped.y >= 0)
        #expect(clamped.x <= guest.width - 1 && clamped.y <= guest.height - 1)
    }

    @Test("Degenerate inputs do not divide by zero")
    func degenerateInputs() {
        #expect(locate(CGPoint(x: 1, y: 1), view: .zero) == .outside(nearest: .zero))
        #expect(locate(CGPoint(x: 1, y: 1), view: CGSize(width: 10, height: 10), guestSize: .zero)
                == .outside(nearest: .zero))
    }
}

@Suite("Keyboard mapping")
struct KeyboardMappingTests {

    @Test("Letters, digits and Enter map to their Linux codes")
    func knownCodes() {
        // Spot-checked against the evdev table; these are the codes QEMU will
        // receive for the most common keys.
        #expect(MacKeyboardMap.linuxKey(forVirtualKey: 0x00) == .a)
        #expect(LinuxKeyCode.a.rawValue == 30)
        #expect(MacKeyboardMap.linuxKey(forVirtualKey: 0x24) == .enter)
        #expect(LinuxKeyCode.enter.rawValue == 28)
        #expect(MacKeyboardMap.linuxKey(forVirtualKey: 0x31) == .space)
        #expect(LinuxKeyCode.space.rawValue == 57)
        #expect(MacKeyboardMap.linuxKey(forVirtualKey: 0x35) == .escape)
        #expect(LinuxKeyCode.escape.rawValue == 1)
    }

    @Test("macOS's non-sequential function keys map correctly")
    func functionKeys() {
        // macOS orders these oddly — F5 is 0x60 and F1 is 0x7A — so an
        // arithmetic conversion would silently mis-map them.
        #expect(MacKeyboardMap.linuxKey(forVirtualKey: 0x7A) == .f1)
        #expect(MacKeyboardMap.linuxKey(forVirtualKey: 0x60) == .f5)
        #expect(MacKeyboardMap.linuxKey(forVirtualKey: 0x6F) == .f12)
    }

    @Test("No two macOS keys map to the same Linux key")
    func mappingIsInjective() {
        let values = MacKeyboardMap.virtualKeyToLinux.values.map(\.rawValue)
        #expect(Set(values).count == values.count, "the keyboard map has duplicate targets")
    }

    @Test("Characters resolve to a key plus a shift flag")
    func characterStrokes() throws {
        let lower = try #require(MacKeyboardMap.keyStroke(for: "a"))
        #expect(lower.key == .a && !lower.shift)

        let upper = try #require(MacKeyboardMap.keyStroke(for: "A"))
        #expect(upper.key == .a && upper.shift)

        let symbol = try #require(MacKeyboardMap.keyStroke(for: ">"))
        #expect(symbol.key == .dot && symbol.shift)

        let newline = try #require(MacKeyboardMap.keyStroke(for: "\n"))
        #expect(newline.key == .enter && !newline.shift)
    }

    @Test("Every printable ASCII character can be typed")
    func asciiCoverage() {
        // The automated verification types a shell command, so a gap here would
        // silently drop characters.
        for scalar in UInt8(0x20)...UInt8(0x7E) {
            let character = Character(UnicodeScalar(scalar))
            #expect(MacKeyboardMap.keyStroke(for: character) != nil,
                    "no key stroke for '\(character)'")
        }
    }

    @Test("Pointer buttons use QEMU's InputButton ordinals, not Linux BTN_ codes")
    func buttonEncoding() {
        // BTN_LEFT is 0x110; sending that would be an out-of-range button.
        #expect(QEMUPointerButton.left.rawValue == 0)
        #expect(QEMUPointerButton.middle.rawValue == 1)
        #expect(QEMUPointerButton.right.rawValue == 2)
        #expect(QEMUPointerButton.wheelUp.rawValue == 3)
        #expect(QEMUPointerButton.wheelDown.rawValue == 4)
    }
}
