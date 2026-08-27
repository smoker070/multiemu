import CoreGraphics
import Foundation

/// A gamepad button, named by role rather than by the label printed on any one
/// vendor's hardware.
public enum GamepadButton: String, Sendable, Codable, CaseIterable, Hashable {
    case a, b, x, y
    case leftShoulder, rightShoulder
    case leftTrigger, rightTrigger
    case leftThumbstickButton, rightThumbstickButton
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case menu, options, home

    public var displayName: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .leftShoulder: return "L1"
        case .rightShoulder: return "R1"
        case .leftTrigger: return "L2"
        case .rightTrigger: return "R2"
        case .leftThumbstickButton: return "L3"
        case .rightThumbstickButton: return "R3"
        case .dpadUp: return "D-pad up"
        case .dpadDown: return "D-pad down"
        case .dpadLeft: return "D-pad left"
        case .dpadRight: return "D-pad right"
        case .menu: return "Menu"
        case .options: return "Options"
        case .home: return "Home"
        }
    }
}

public enum GamepadStick: String, Sendable, Codable, CaseIterable, Hashable {
    case left, right

    public var displayName: String { self == .left ? "Left stick" : "Right stick" }
}

/// The whole state of a gamepad at one instant.
///
/// A value rather than a stream of deltas: the mapper compares it against the
/// previous state to decide what changed, which keeps the translation a pure
/// function and lets it be tested without any hardware.
public struct GamepadSnapshot: Sendable, Equatable {
    public var pressedButtons: Set<GamepadButton>
    /// Each axis runs -1…1, y positive **downwards** to match screen space.
    public var leftStick: CGPoint
    public var rightStick: CGPoint

    public init(
        pressedButtons: Set<GamepadButton> = [],
        leftStick: CGPoint = .zero,
        rightStick: CGPoint = .zero
    ) {
        self.pressedButtons = pressedButtons
        self.leftStick = leftStick
        self.rightStick = rightStick
    }

    public static let neutral = GamepadSnapshot()

    public func stick(_ which: GamepadStick) -> CGPoint {
        which == .left ? leftStick : rightStick
    }

    /// Ignores drift around centre.
    ///
    /// Without this a resting stick produces a continuous dribble of touch
    /// updates, which reads to the guest as a held finger that never settles.
    public func applyingDeadzone(_ deadzone: Double) -> GamepadSnapshot {
        func clean(_ point: CGPoint) -> CGPoint {
            let magnitude = (point.x * point.x + point.y * point.y).squareRoot()
            return magnitude < deadzone ? .zero : point
        }
        return GamepadSnapshot(
            pressedButtons: pressedButtons,
            leftStick: clean(leftStick),
            rightStick: clean(rightStick)
        )
    }
}
