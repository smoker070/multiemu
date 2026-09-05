import CoreGraphics
import Foundation

/// One instruction for the guest, produced from a host pointer event.
///
/// A list of these is a complete gesture, so the policy that decides *what a
/// mouse means to Android* can be tested without a running guest.
public enum GuestPointerCommand: Equatable, Sendable {
    case touchBegin(CGPoint)
    case touchUpdate(CGPoint)
    case touchEnd(CGPoint)
    case touchCancel(CGPoint)
    /// A pointer move with no button held. Android draws no cursor for this,
    /// but a guest that does keeps tracking the mouse.
    case hover(CGPoint)
    /// The caller must pace the gesture here before sending what follows.
    case wait(milliseconds: Int)
}

/// Turns host mouse events into guest touches.
///
/// Multiemu attaches both a virtio tablet and a virtio multitouch device, and
/// QEMU routes their events independently: a `SetAbsPosition` reaches the
/// tablet while the button that should accompany it reaches the multitouch
/// device. `getevent` in the guest shows the split directly —
///
///     /dev/input/event2: EV_ABS  ABS_X      00003fff   (tablet)
///     /dev/input/event3: EV_KEY  BTN_MOUSE  DOWN       (multitouch)
///
/// — and Android, which keys pointer state to the device a button arrives on,
/// sees a button with no position and a position with no button. Every click
/// is silently dropped. A pointer drag across the launcher leaves the screen
/// byte-identical; the same drag as a touch changes it.
///
/// So a mouse is presented to the guest as a finger. That is also the right
/// model regardless of the bug: Android is a touch platform, and a tap is what
/// its views are listening for.
public struct PointerTouchTranslator: Sendable {

    /// How long a right-click holds before releasing, to read as a long press.
    /// Android's own `ViewConfiguration` long-press timeout is 500 ms; this
    /// leaves a margin above it.
    public static let longPressMilliseconds = 650

    /// Steps a wheel notch is broken into. A begin/end pair with no motion
    /// between them is a tap, not a scroll.
    public static let scrollSteps = 8

    /// Guest pixels travelled per line of wheel scroll.
    public static let scrollPixelsPerLine = 40.0

    private var isTouching = false
    private var lastPoint: CGPoint = .zero

    public init() {}

    /// True between a press and its release.
    public var isDown: Bool { isTouching }

    public mutating func moved(to point: CGPoint) -> [GuestPointerCommand] {
        lastPoint = point
        // A move with the button down is a drag, and must stay on the touch
        // device: switching to `hover` mid-drag would strand the finger.
        return isTouching ? [.touchUpdate(point)] : [.hover(point)]
    }

    public mutating func pressed(
        _ button: QEMUPointerButton,
        at point: CGPoint
    ) -> [GuestPointerCommand] {
        lastPoint = point
        switch button {
        case .left:
            guard !isTouching else { return [.touchUpdate(point)] }
            isTouching = true
            // The position rides on `.update`, not `.begin`. A tap sent as a
            // bare begin/end pair reaches the guest with no coordinate at all,
            // which is how an earlier probe saw a touch arrive at nowhere.
            return [.touchBegin(point), .touchUpdate(point)]
        case .right:
            // Android has no second button; the equivalent gesture is a press
            // held past the long-press timeout.
            guard !isTouching else { return [] }
            isTouching = true
            return [.touchBegin(point), .touchUpdate(point),
                    .wait(milliseconds: Self.longPressMilliseconds)]
        default:
            // Middle and the rest have no touch equivalent. Dropping them is
            // honest; forwarding them as taps would make a middle-click open
            // whatever it happened to be over.
            return []
        }
    }

    public mutating func released(
        _ button: QEMUPointerButton,
        at point: CGPoint?
    ) -> [GuestPointerCommand] {
        guard isTouching, button == .left || button == .right else { return [] }
        isTouching = false
        let end = point ?? lastPoint
        lastPoint = end
        return [.touchUpdate(end), .touchEnd(end)]
    }

    /// Focus loss, or the window closing. A finger left down in the guest makes
    /// the emulator look hung.
    public mutating func cancelled() -> [GuestPointerCommand] {
        guard isTouching else { return [] }
        isTouching = false
        return [.touchCancel(lastPoint)]
    }

    /// A wheel notch, as the drag a touch platform expects.
    ///
    /// `lines` is positive for scrolling up — the same sign AppKit reports —
    /// and content follows the finger, so scrolling up drags downward.
    public mutating func scrolled(
        lines: Int,
        at point: CGPoint,
        guestSize: CGSize
    ) -> [GuestPointerCommand] {
        guard lines != 0, !isTouching else { return [] }
        let travel = Double(lines) * Self.scrollPixelsPerLine

        // Start the drag away from the edge it travels towards, so a long
        // scroll does not run off the screen and stop early.
        let start = CGPoint(
            x: point.x.clamped(to: 0...max(0, guestSize.width - 1)),
            y: (guestSize.height / 2 - travel / 2)
                .clamped(to: 0...max(0, guestSize.height - 1))
        )

        var commands: [GuestPointerCommand] = [.touchBegin(start), .touchUpdate(start)]
        for step in 1...Self.scrollSteps {
            let progress = Double(step) / Double(Self.scrollSteps)
            let y = (start.y + travel * progress)
                .clamped(to: 0...max(0, guestSize.height - 1))
            commands.append(.wait(milliseconds: 8))
            commands.append(.touchUpdate(CGPoint(x: start.x, y: y)))
        }
        let endY = (start.y + travel).clamped(to: 0...max(0, guestSize.height - 1))
        commands.append(.touchEnd(CGPoint(x: start.x, y: endY)))
        return commands
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<Double>) -> CGFloat {
        CGFloat(Swift.min(Swift.max(Double(self), range.lowerBound), range.upperBound))
    }
}

public extension QEMUInputClient {
    /// Sends a translated gesture. The waits are part of the gesture: a long
    /// press that does not outlast Android's timeout is an ordinary tap.
    func perform(_ commands: [GuestPointerCommand]) async throws {
        for command in commands {
            switch command {
            case .touchBegin(let point):  try await touch(.begin, x: point.x, y: point.y)
            case .touchUpdate(let point): try await touch(.update, x: point.x, y: point.y)
            case .touchEnd(let point):    try await touch(.end, x: point.x, y: point.y)
            case .touchCancel(let point): try await touch(.cancel, x: point.x, y: point.y)
            case .hover(let point):       try await moveAbsolute(to: point)
            case .wait(let milliseconds): try await Task.sleep(for: .milliseconds(milliseconds))
            }
        }
    }
}
