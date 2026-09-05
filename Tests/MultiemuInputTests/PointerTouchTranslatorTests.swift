import CoreGraphics
import XCTest
@testable import MultiemuInput

/// A mouse reaches Android as a finger. The rule these cover is not a style
/// choice: `getevent` in the guest showed QEMU delivering a click's position to
/// the virtio tablet and its button to the virtio multitouch device, so a
/// pointer click is never assembled into a click at all. A pointer drag across
/// the launcher left the screen byte-identical; the same drag as a touch
/// changed it.
final class PointerTouchTranslatorTests: XCTestCase {

    func testLeftClickBecomesATouchThatCarriesItsPosition() {
        var translator = PointerTouchTranslator()
        let point = CGPoint(x: 400, y: 900)

        // A bare begin/end pair reaches the guest with no coordinate: the
        // position rides on `.update`. The tap must contain one.
        XCTAssertEqual(translator.pressed(.left, at: point),
                       [.touchBegin(point), .touchUpdate(point)])
        XCTAssertEqual(translator.released(.left, at: point),
                       [.touchUpdate(point), .touchEnd(point)])
    }

    func testNoPointerButtonIsEverEmitted() {
        var translator = PointerTouchTranslator()
        var emitted: [GuestPointerCommand] = []
        emitted += translator.pressed(.left, at: CGPoint(x: 10, y: 10))
        emitted += translator.moved(to: CGPoint(x: 20, y: 20))
        emitted += translator.released(.left, at: CGPoint(x: 20, y: 20))
        emitted += translator.scrolled(lines: 3, at: CGPoint(x: 5, y: 5),
                                       guestSize: CGSize(width: 100, height: 100))
        // `hover` is the only non-touch command, and it may not appear inside a
        // drag. Nothing here may be a button press, which is the whole point.
        XCTAssertFalse(emitted.contains(.hover(CGPoint(x: 20, y: 20))))
    }

    func testMoveWithTheButtonDownDragsRatherThanHovers() {
        var translator = PointerTouchTranslator()
        _ = translator.pressed(.left, at: CGPoint(x: 10, y: 10))
        XCTAssertEqual(translator.moved(to: CGPoint(x: 30, y: 40)),
                       [.touchUpdate(CGPoint(x: 30, y: 40))])
        _ = translator.released(.left, at: nil)
        // With no finger down the same motion is a hover, so a guest that draws
        // a cursor still tracks the mouse.
        XCTAssertEqual(translator.moved(to: CGPoint(x: 50, y: 60)),
                       [.hover(CGPoint(x: 50, y: 60))])
    }

    func testReleaseWithoutAPositionEndsWhereTheFingerWas() {
        var translator = PointerTouchTranslator()
        _ = translator.pressed(.left, at: CGPoint(x: 10, y: 10))
        _ = translator.moved(to: CGPoint(x: 77, y: 88))
        // A release outside the image reports no point; ending at .zero would
        // fling the gesture to the corner.
        XCTAssertEqual(translator.released(.left, at: nil),
                       [.touchUpdate(CGPoint(x: 77, y: 88)),
                        .touchEnd(CGPoint(x: 77, y: 88))])
    }

    func testRightClickHoldsPastAndroidsLongPressTimeout() {
        var translator = PointerTouchTranslator()
        let commands = translator.pressed(.right, at: CGPoint(x: 1, y: 2))
        let held = commands.compactMap { command -> Int? in
            if case .wait(let milliseconds) = command { return milliseconds }
            return nil
        }.reduce(0, +)
        // Android's own long-press timeout is 500 ms; a shorter hold is a tap.
        XCTAssertGreaterThan(held, 500)
    }

    func testMiddleClickIsDroppedRatherThanTurnedIntoATap() {
        var translator = PointerTouchTranslator()
        XCTAssertEqual(translator.pressed(.middle, at: CGPoint(x: 1, y: 1)), [])
        XCTAssertFalse(translator.isDown)
        XCTAssertEqual(translator.released(.middle, at: CGPoint(x: 1, y: 1)), [])
    }

    func testCancellationLiftsAFingerThatReleaseAllWouldLeaveDown() {
        var translator = PointerTouchTranslator()
        _ = translator.pressed(.left, at: CGPoint(x: 5, y: 6))
        XCTAssertEqual(translator.cancelled(), [.touchCancel(CGPoint(x: 5, y: 6))])
        XCTAssertFalse(translator.isDown)
        // Idempotent: a second focus loss must not send a stray cancel.
        XCTAssertEqual(translator.cancelled(), [])
    }

    func testScrollIsADragAndStaysOnTheScreen() {
        var translator = PointerTouchTranslator()
        let size = CGSize(width: 1920, height: 1920)
        let commands = translator.scrolled(lines: 40, at: CGPoint(x: 960, y: 100),
                                           guestSize: size)
        let points: [CGPoint] = commands.compactMap { command in
            switch command {
            case .touchBegin(let p), .touchUpdate(let p), .touchEnd(let p): return p
            default: return nil
            }
        }
        XCTAssertGreaterThan(points.count, 3, "a begin/end pair is a tap, not a scroll")
        for point in points {
            XCTAssertTrue((0...size.width).contains(point.x))
            XCTAssertTrue((0...size.height).contains(point.y), "ran off the screen at \(point)")
        }
        XCTAssertNotEqual(points.first?.y, points.last?.y, "the finger never moved")
    }

    func testScrollIsIgnoredMidDragRatherThanStartingASecondFinger() {
        var translator = PointerTouchTranslator()
        _ = translator.pressed(.left, at: CGPoint(x: 10, y: 10))
        XCTAssertEqual(translator.scrolled(lines: 5, at: CGPoint(x: 10, y: 10),
                                           guestSize: CGSize(width: 100, height: 100)), [])
    }
}

/// The wire ordinals these pin come from QEMU's `qapi/ui.json`, which lists
/// `InputMultiTouchType` as `[ 'begin', 'update', 'end', 'cancel', 'data' ]`.
/// Getting `end` and `cancel` the wrong way round is not rejected by QEMU —
/// both are accepted kinds — so nothing fails; the guest simply never sees the
/// finger lift.
final class QEMUMultiTouchKindTests: XCTestCase {
    func testOrdinalsMatchQEMUsEnumOrder() {
        XCTAssertEqual(QEMUMultiTouchKind.begin.rawValue, 0)
        XCTAssertEqual(QEMUMultiTouchKind.update.rawValue, 1)
        XCTAssertEqual(QEMUMultiTouchKind.end.rawValue, 2)
        XCTAssertEqual(QEMUMultiTouchKind.cancel.rawValue, 3)
    }

    func testEndAndCancelAreNotInterchangeable() {
        // Only `end` clears the slot's tracking id in QEMU, so swapping these
        // two produces a touch that never lifts.
        XCTAssertNotEqual(QEMUMultiTouchKind.end.rawValue,
                          QEMUMultiTouchKind.cancel.rawValue)
    }
}
