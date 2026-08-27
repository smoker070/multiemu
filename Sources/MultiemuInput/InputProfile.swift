import CoreGraphics
import Foundation

/// A point on the guest display, expressed as a fraction of its size.
///
/// Normalised rather than in pixels so that a profile survives a resolution
/// change: a button placed at the bottom-right of a 1280×720 guest is still at
/// the bottom-right after the device is reconfigured to 1920×1080.
public struct NormalizedPoint: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// Clamped to the display, because a binding placed off-screen would send
    /// touches the guest silently ignores.
    public var clamped: NormalizedPoint {
        NormalizedPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    public func inPixels(of size: CGSize) -> CGPoint {
        let point = clamped
        return CGPoint(x: point.x * size.width, y: point.y * size.height)
    }
}

/// One of the four directions a discrete trigger can push a virtual stick.
public enum StickDirection: String, Sendable, Codable, CaseIterable {
    case up, down, left, right

    var vector: (dx: Double, dy: Double) {
        switch self {
        case .up: return (0, -1)
        case .down: return (0, 1)
        case .left: return (-1, 0)
        case .right: return (1, 0)
        }
    }
}

/// A virtual joystick drawn on the guest screen.
///
/// Several triggers drive one stick by sharing a `stickID`, which is what makes
/// W/A/S/D behave as a single control rather than four unrelated touches — and
/// what makes diagonals work.
public struct StickBinding: Sendable, Equatable, Codable {
    public var stickID: String
    public var center: NormalizedPoint
    /// Throw distance, as a fraction of the display's **shorter** edge, so the
    /// stick stays circular on a wide screen instead of stretching.
    public var radius: Double
    /// The direction a discrete trigger pushes. `nil` for an analog trigger,
    /// which supplies its own vector.
    public var direction: StickDirection?

    public init(stickID: String, center: NormalizedPoint, radius: Double = 0.12,
                direction: StickDirection? = nil) {
        self.stickID = stickID
        self.center = center
        self.radius = radius
        self.direction = direction
    }
}

/// What produces an input.
public enum InputTrigger: Sendable, Equatable, Codable, Hashable {
    case key(LinuxKeyCode)
    case gamepadButton(GamepadButton)
    /// An analog stick. Its own vector drives the action.
    case gamepadStick(GamepadStick)
}

/// What the guest receives.
public enum InputAction: Sendable, Equatable, Codable {
    /// Hold a touch at a point for as long as the trigger is held. The building
    /// block for on-screen buttons.
    case touch(NormalizedPoint)
    /// Contribute to a virtual joystick.
    case stick(StickBinding)
    /// Pass a key straight through to the guest's keyboard.
    ///
    /// Which Android action a given key reaches is a property of the guest's
    /// key layout, and this project has not yet run an Android guest — so no
    /// specific mapping is claimed here. See `docs/VERIFY.md`,
    /// `ANDROID-KEY-SEMANTICS`.
    case key(LinuxKeyCode)
}

public struct InputBinding: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    /// Shown in the interface and in the activity log, so a misfiring binding
    /// can be named rather than described by coordinates.
    public var label: String
    public var trigger: InputTrigger
    public var action: InputAction

    public init(id: UUID = UUID(), label: String, trigger: InputTrigger, action: InputAction) {
        self.id = id
        self.label = label
        self.trigger = trigger
        self.action = action
    }
}

/// A named set of bindings, saved with the device.
public struct InputProfile: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var bindings: [InputBinding]

    public init(id: UUID = UUID(), name: String, bindings: [InputBinding] = []) {
        self.id = id
        self.name = name
        self.bindings = bindings
    }

    /// Bindings that would never fire, or that fight each other.
    ///
    /// Reported rather than silently repaired: a profile that quietly drops half
    /// its bindings is harder to debug than one that says what is wrong.
    public func problems() -> [String] {
        var problems: [String] = []
        var seenTriggers: [InputTrigger: String] = [:]

        for binding in bindings {
            if let existing = seenTriggers[binding.trigger] {
                problems.append(
                    "\"\(binding.label)\" and \"\(existing)\" both respond to the same control.")
            } else {
                seenTriggers[binding.trigger] = binding.label
            }

            switch binding.action {
            case let .touch(point):
                if point != point.clamped {
                    problems.append("\"\(binding.label)\" is placed off the screen.")
                }
            case let .stick(stick):
                if stick.center != stick.center.clamped {
                    problems.append("\"\(binding.label)\" has its centre off the screen.")
                }
                if stick.radius <= 0 || stick.radius > 0.5 {
                    problems.append(
                        "\"\(binding.label)\" has a throw distance of \(stick.radius); it must be above 0 and at most 0.5.")
                }
                if case .gamepadStick = binding.trigger, stick.direction != nil {
                    problems.append(
                        "\"\(binding.label)\" binds an analog stick to a fixed direction; leave the direction unset.")
                }
                if case .gamepadStick = binding.trigger {} else if stick.direction == nil {
                    problems.append(
                        "\"\(binding.label)\" drives a stick from a button but has no direction.")
                }
            case .key:
                break
            }
        }

        // Bindings that share a stickID describe ONE control, so they must agree
        // about where it is. Disagreeing centres make the touch that lifts the
        // stick end somewhere the touch that began it never was.
        var geometry: [String: (centre: NormalizedPoint, radius: Double, label: String)] = [:]
        var analogTriggers: [String: String] = [:]
        for binding in bindings {
            guard case let .stick(stick) = binding.action else { continue }
            if let existing = geometry[stick.stickID] {
                if existing.centre != stick.center || existing.radius != stick.radius {
                    problems.append("""
                        \"\(binding.label)\" and \"\(existing.label)\" drive the same stick but place it \
                        differently.
                        """)
                }
            } else {
                geometry[stick.stickID] = (stick.center, stick.radius, binding.label)
            }

            // Two analog triggers on one stick would overwrite each other's
            // vector, so only the last one moved would have any effect.
            if case .gamepadStick = binding.trigger {
                if let existing = analogTriggers[stick.stickID] {
                    problems.append("""
                        \"\(binding.label)\" and \"\(existing)\" both drive the same stick with an analog \
                        control; only one of them can.
                        """)
                } else {
                    analogTriggers[stick.stickID] = binding.label
                }
            }
        }
        return problems
    }
}


extension InputProfile {

    /// A starting layout: a movement stick on the left, action buttons on the
    /// right, and the same controls mirrored onto a gamepad.
    ///
    /// Positions follow the convention touch games have settled on, so a new
    /// device is usable before anyone edits anything. It is a starting point,
    /// not a claim about any particular game.
    /// Fixed identity for the synthesised default.
    ///
    /// A device with no saved mapping is given this one on the fly, and a fresh
    /// `UUID()` per call would mean the active-profile id never matched
    /// anything — selecting a mapping and showing which one is active would both
    /// quietly do nothing.
    public static let starterID = UUID(uuidString: "0000A16C-0000-4000-8000-000000000000")!

    /// Stable identity per binding, for the same reason: the synthesised profile
    /// must compare equal to itself across calls.
    private static func starterBindingID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "0000A16C-0000-4000-8000-%012d", index))!
    }

    /// The synthesised default, with a fixed identity.
    ///
    /// Distinct from `newProfile(named:)`: the default must be the *same*
    /// profile every time a device without a saved mapping is asked for one,
    /// while a profile the user creates from the same layout must be a new one.
    public static var starter: InputProfile { layout(id: starterID, name: "Default") }

    /// A fresh copy of the starter layout, with its own identity, for creating a
    /// mapping the user will then edit.
    public static func newProfile(named name: String) -> InputProfile {
        layout(id: UUID(), name: name)
    }

    private static func layout(id: UUID, name: String) -> InputProfile {
        let stickCentre = NormalizedPoint(x: 0.18, y: 0.72)
        let stickRadius = 0.11

        var ordinal = 0
        // Deterministic only for the synthesised default; a user-created profile
        // gets fresh binding ids so two profiles never share one.
        let deterministic = id == starterID
        func nextID() -> UUID {
            defer { ordinal += 1 }
            return deterministic ? starterBindingID(ordinal) : UUID()
        }
        func movement(_ key: LinuxKeyCode, _ direction: StickDirection) -> InputBinding {
            InputBinding(
                id: nextID(),
                label: "Move \(direction.rawValue)",
                trigger: .key(key),
                action: .stick(StickBinding(
                    stickID: "movement", center: stickCentre,
                    radius: stickRadius, direction: direction)))
        }

        return InputProfile(id: id, name: name, bindings: [
            movement(.w, .up), movement(.s, .down), movement(.a, .left), movement(.d, .right),
            InputBinding(id: nextID(), label: "Primary", trigger: .key(.space),
                         action: .touch(NormalizedPoint(x: 0.88, y: 0.76))),
            InputBinding(id: nextID(), label: "Secondary", trigger: .key(.j),
                         action: .touch(NormalizedPoint(x: 0.78, y: 0.84))),
            InputBinding(id: nextID(), label: "Tertiary", trigger: .key(.k),
                         action: .touch(NormalizedPoint(x: 0.78, y: 0.66))),

            InputBinding(id: nextID(), label: "Move", trigger: .gamepadStick(.left),
                         action: .stick(StickBinding(
                            stickID: "movement", center: stickCentre, radius: stickRadius))),
            InputBinding(id: nextID(), label: "Primary", trigger: .gamepadButton(.a),
                         action: .touch(NormalizedPoint(x: 0.88, y: 0.76))),
            InputBinding(id: nextID(), label: "Secondary", trigger: .gamepadButton(.x),
                         action: .touch(NormalizedPoint(x: 0.78, y: 0.84))),
            InputBinding(id: nextID(), label: "Tertiary", trigger: .gamepadButton(.y),
                         action: .touch(NormalizedPoint(x: 0.78, y: 0.66))),
        ])
    }
}
