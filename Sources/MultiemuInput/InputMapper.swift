import CoreGraphics
import Foundation

/// One input the guest should receive. Coordinates are guest **pixels**, which
/// is what `org.qemu.Display1.MultiTouch.SendEvent` expects.
public enum GuestInputEvent: Sendable, Equatable {
    case touchBegin(slot: UInt64, x: Double, y: Double)
    case touchUpdate(slot: UInt64, x: Double, y: Double)
    case touchEnd(slot: UInt64, x: Double, y: Double)
    case keyPress(LinuxKeyCode)
    case keyRelease(LinuxKeyCode)
}

/// Translates held keys and stick positions into guest input.
///
/// Deliberately a value type with no I/O: every rule here — which slot a touch
/// takes, how W and D combine into a diagonal, what happens when a profile is
/// swapped mid-press — is decided by a pure function and can be tested without
/// a guest, a gamepad, or a display.
public struct InputMapper: Sendable {

    /// QEMU reports its own limit over D-Bus (`MultiTouch.MaxSlots`, 10 on the
    /// builds measured). Exceeding it does not fail loudly, so the mapper
    /// enforces it rather than letting touches silently go nowhere.
    public private(set) var maximumSlots: Int

    public private(set) var profile: InputProfile
    public var guestSize: CGSize

    /// Reported when a binding could not be honoured. Read and cleared by the
    /// caller so it can reach the activity log instead of vanishing.
    public private(set) var diagnostics: [String] = []

    /// Slot currently held by a `.touch` binding.
    private var touchSlots: [UUID: UInt64] = [:]
    /// Slot currently held by a virtual stick, keyed by `stickID`.
    private var stickSlots: [String: UInt64] = [:]
    private var usedSlots: Set<UInt64> = []

    private var heldKeys: Set<LinuxKeyCode> = []
    /// Guest keys a binding is currently holding down, keyed by binding.
    ///
    /// Recorded per binding rather than derived from `heldKeys`, because a key
    /// action can be driven by a gamepad button too — and a key pressed that way
    /// was never in `heldKeys` at all, so nothing could ever release it.
    private var engagedKeys: [UUID: LinuxKeyCode] = [:]
    private var lastGamepad = GamepadSnapshot.neutral
    /// Directions currently pushed on each stick by discrete triggers.
    private var stickDirections: [String: Set<StickDirection>] = [:]
    /// Analog contribution to each stick, -1…1 per axis.
    private var stickVectors: [String: CGPoint] = [:]

    public init(profile: InputProfile, guestSize: CGSize, maximumSlots: Int = 10) {
        self.profile = profile
        self.guestSize = guestSize
        self.maximumSlots = max(1, maximumSlots)
    }

    /// True when this profile claims the key, so the caller knows not to also
    /// forward it to the guest keyboard.
    public func handles(_ key: LinuxKeyCode) -> Bool {
        profile.bindings.contains { $0.trigger == .key(key) }
    }

    public mutating func takeDiagnostics() -> [String] {
        defer { diagnostics.removeAll() }
        return diagnostics
    }

    // MARK: - Keyboard

    public mutating func keyDown(_ key: LinuxKeyCode) -> [GuestInputEvent] {
        // Auto-repeat arrives as a stream of key-downs; only the first is a
        // press, and re-sending touchBegin would look like a second finger.
        guard heldKeys.insert(key).inserted else { return [] }
        return apply(trigger: .key(key), engaged: true)
    }

    public mutating func keyUp(_ key: LinuxKeyCode) -> [GuestInputEvent] {
        guard heldKeys.remove(key) != nil else { return [] }
        return apply(trigger: .key(key), engaged: false)
    }

    // MARK: - Gamepad

    /// Applies a whole gamepad state, emitting only what changed since the last.
    public mutating func apply(_ snapshot: GamepadSnapshot) -> [GuestInputEvent] {
        var events: [GuestInputEvent] = []

        let pressed = snapshot.pressedButtons.subtracting(lastGamepad.pressedButtons)
        let released = lastGamepad.pressedButtons.subtracting(snapshot.pressedButtons)
        for button in pressed.sorted(by: { $0.rawValue < $1.rawValue }) {
            events += apply(trigger: .gamepadButton(button), engaged: true)
        }
        for button in released.sorted(by: { $0.rawValue < $1.rawValue }) {
            events += apply(trigger: .gamepadButton(button), engaged: false)
        }

        for which in GamepadStick.allCases where snapshot.stick(which) != lastGamepad.stick(which) {
            for binding in profile.bindings where binding.trigger == .gamepadStick(which) {
                guard case let .stick(stick) = binding.action else { continue }
                stickVectors[stick.stickID] = snapshot.stick(which)
                events += resolveStick(stick)
            }
        }

        lastGamepad = snapshot
        return events
    }

    // MARK: - Release

    /// Lifts everything currently held.
    ///
    /// Needed whenever the window loses focus or a profile is swapped: a touch
    /// left down in the guest is a finger that never lifts, and the guest has no
    /// way to recover from it.
    public mutating func releaseAll() -> [GuestInputEvent] {
        var events: [GuestInputEvent] = []
        for (id, slot) in touchSlots.sorted(by: { $0.value < $1.value }) {
            let point = touchPoint(forBindingID: id) ?? .zero
            events.append(.touchEnd(slot: slot, x: Double(point.x), y: Double(point.y)))
        }
        for (stickID, slot) in stickSlots.sorted(by: { $0.value < $1.value }) {
            let centre = centre(ofStick: stickID) ?? .zero
            events.append(.touchEnd(slot: slot, x: Double(centre.x), y: Double(centre.y)))
        }
        // Every key a binding is holding, whatever drove it. The old version
        // searched the profile by trigger, which returned the wrong binding when
        // two shared one — leaving a key down in the guest permanently.
        for key in engagedKeys.values.sorted(by: { $0.rawValue < $1.rawValue }) {
            events.append(.keyRelease(key))
        }

        touchSlots.removeAll()
        stickSlots.removeAll()
        usedSlots.removeAll()
        heldKeys.removeAll()
        engagedKeys.removeAll()
        stickDirections.removeAll()
        stickVectors.removeAll()
        // `lastGamepad` is deliberately NOT reset. It records what the hardware
        // is physically holding; clearing it makes the next unrelated stick
        // wobble look like a fresh press of every button still held, which the
        // guest receives while the window is not even focused.
        return events
    }

    /// Swaps the profile, lifting anything the old one was holding first.
    public mutating func replaceProfile(_ newProfile: InputProfile) -> [GuestInputEvent] {
        let released = releaseAll()
        profile = newProfile
        return released
    }

    // MARK: - Translation

    private mutating func apply(trigger: InputTrigger, engaged: Bool) -> [GuestInputEvent] {
        var events: [GuestInputEvent] = []
        for binding in profile.bindings where binding.trigger == trigger {
            switch binding.action {
            case let .touch(point):
                events += resolveTouch(binding: binding, point: point, engaged: engaged)
            case let .stick(stick):
                guard let direction = stick.direction else { continue }
                var held = stickDirections[stick.stickID] ?? []
                if engaged { held.insert(direction) } else { held.remove(direction) }
                stickDirections[stick.stickID] = held
                events += resolveStick(stick)
            case let .key(guestKey):
                // Tracked per binding so every press has exactly one release,
                // even when two bindings share a trigger.
                if engaged {
                    guard engagedKeys[binding.id] == nil else { continue }
                    engagedKeys[binding.id] = guestKey
                    events.append(.keyPress(guestKey))
                } else {
                    guard engagedKeys.removeValue(forKey: binding.id) != nil else { continue }
                    events.append(.keyRelease(guestKey))
                }
            }
        }
        return events
    }

    private mutating func resolveTouch(
        binding: InputBinding, point: NormalizedPoint, engaged: Bool
    ) -> [GuestInputEvent] {
        let pixel = point.inPixels(of: guestSize)
        if engaged {
            guard touchSlots[binding.id] == nil else { return [] }
            guard let slot = takeSlot() else {
                diagnostics.append(
                    "\"\(binding.label)\" was ignored: all \(maximumSlots) touch points are in use.")
                return []
            }
            touchSlots[binding.id] = slot
            return [.touchBegin(slot: slot, x: Double(pixel.x), y: Double(pixel.y))]
        } else {
            guard let slot = touchSlots.removeValue(forKey: binding.id) else { return [] }
            releaseSlot(slot)
            return [.touchEnd(slot: slot, x: Double(pixel.x), y: Double(pixel.y))]
        }
    }

    private mutating func resolveStick(_ stick: StickBinding) -> [GuestInputEvent] {
        let vector = currentVector(for: stick)
        let centre = stick.center.inPixels(of: guestSize)

        // The throw is measured against the shorter edge so the stick describes
        // a circle rather than an ellipse on a wide display.
        let shorterEdge = min(guestSize.width, guestSize.height)
        let reach = stick.radius * Double(shorterEdge)
        // Clamped: a centre near an edge with a generous throw would otherwise
        // send touches off the display, which the guest silently ignores.
        let target = CGPoint(
            x: min(max(centre.x + CGFloat(vector.x * reach), 0), guestSize.width),
            y: min(max(centre.y + CGFloat(vector.y * reach), 0), guestSize.height)
        )

        // Whether anything is *engaged*, which is not the same as whether the
        // vector is zero: holding left and right together cancels out, but the
        // finger should stay on the stick at its centre rather than lift off and
        // land again when one of them is released.
        let engaged = !(stickDirections[stick.stickID] ?? []).isEmpty
            || (stickVectors[stick.stickID].map { $0 != .zero } ?? false)

        if !engaged {
            guard let slot = stickSlots.removeValue(forKey: stick.stickID) else { return [] }
            releaseSlot(slot)
            return [.touchEnd(slot: slot, x: Double(centre.x), y: Double(centre.y))]
        }

        if let slot = stickSlots[stick.stickID] {
            return [.touchUpdate(slot: slot, x: Double(target.x), y: Double(target.y))]
        }
        guard let slot = takeSlot() else {
            diagnostics.append(
                "Stick \"\(stick.stickID)\" was ignored: all \(maximumSlots) touch points are in use.")
            return []
        }
        stickSlots[stick.stickID] = slot
        // Begin at the centre, then move: a stick that appears already deflected
        // reads to the guest as a finger that teleported onto the screen.
        return [
            .touchBegin(slot: slot, x: Double(centre.x), y: Double(centre.y)),
            .touchUpdate(slot: slot, x: Double(target.x), y: Double(target.y)),
        ]
    }

    /// Combines discrete directions and any analog contribution, then clamps to
    /// the unit circle so a diagonal is not longer than a cardinal push.
    private func currentVector(for stick: StickBinding) -> (x: Double, y: Double) {
        var x = 0.0
        var y = 0.0
        for direction in stickDirections[stick.stickID] ?? [] {
            x += direction.vector.dx
            y += direction.vector.dy
        }
        if let analog = stickVectors[stick.stickID] {
            x += Double(analog.x)
            y += Double(analog.y)
        }
        let magnitude = (x * x + y * y).squareRoot()
        guard magnitude > 1 else { return (x, y) }
        return (x / magnitude, y / magnitude)
    }

    // MARK: - Slots

    private mutating func takeSlot() -> UInt64? {
        for candidate in 0..<UInt64(maximumSlots) where !usedSlots.contains(candidate) {
            usedSlots.insert(candidate)
            return candidate
        }
        return nil
    }

    private mutating func releaseSlot(_ slot: UInt64) {
        usedSlots.remove(slot)
    }

    private func touchPoint(forBindingID id: UUID) -> CGPoint? {
        guard let binding = profile.bindings.first(where: { $0.id == id }),
              case let .touch(point) = binding.action else { return nil }
        return point.inPixels(of: guestSize)
    }

    private func centre(ofStick stickID: String) -> CGPoint? {
        for binding in profile.bindings {
            if case let .stick(stick) = binding.action, stick.stickID == stickID {
                return stick.center.inPixels(of: guestSize)
            }
        }
        return nil
    }
}
