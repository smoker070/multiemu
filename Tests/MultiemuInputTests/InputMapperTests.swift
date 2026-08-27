import CoreGraphics
import Foundation
import Testing
@testable import MultiemuInput

@Suite("Input mapping")
struct InputMapperTests {

    private let guestSize = CGSize(width: 1920, height: 1080)

    private func fireButton(at point: NormalizedPoint, key: LinuxKeyCode = .space) -> InputBinding {
        InputBinding(label: "Fire", trigger: .key(key), action: .touch(point))
    }

    private func moveStick(
        key: LinuxKeyCode, direction: StickDirection,
        center: NormalizedPoint = NormalizedPoint(x: 0.2, y: 0.7), radius: Double = 0.1
    ) -> InputBinding {
        InputBinding(
            label: "Move \(direction.rawValue)", trigger: .key(key),
            action: .stick(StickBinding(stickID: "move", center: center, radius: radius, direction: direction)))
    }

    // MARK: - Keys to screen positions

    @Test("A bound key becomes a touch at the mapped position, held until release")
    func keyBecomesHeldTouch() {
        let point = NormalizedPoint(x: 0.8, y: 0.75)
        var mapper = InputMapper(
            profile: InputProfile(name: "Test", bindings: [fireButton(at: point)]),
            guestSize: guestSize)

        #expect(mapper.keyDown(.space) == [.touchBegin(slot: 0, x: 1536, y: 810)])
        // Held: nothing further until release.
        #expect(mapper.keyDown(.space).isEmpty)
        #expect(mapper.keyUp(.space) == [.touchEnd(slot: 0, x: 1536, y: 810)])
    }

    @Test("Auto-repeat does not produce a second finger")
    func autoRepeatIsIdempotent() {
        var mapper = InputMapper(
            profile: InputProfile(name: "Test", bindings: [fireButton(at: NormalizedPoint(x: 0.5, y: 0.5))]),
            guestSize: guestSize)
        _ = mapper.keyDown(.space)
        // macOS delivers a stream of key-downs while a key is held.
        for _ in 1...20 { #expect(mapper.keyDown(.space).isEmpty) }
        #expect(mapper.keyUp(.space).count == 1)
    }

    @Test("A position is a fraction of the display, so it survives a resolution change")
    func positionsAreResolutionIndependent() {
        let point = NormalizedPoint(x: 0.25, y: 0.5)
        let profile = InputProfile(name: "Test", bindings: [fireButton(at: point)])

        var small = InputMapper(profile: profile, guestSize: CGSize(width: 1280, height: 720))
        var large = InputMapper(profile: profile, guestSize: CGSize(width: 2560, height: 1440))

        #expect(small.keyDown(.space) == [.touchBegin(slot: 0, x: 320, y: 360)])
        #expect(large.keyDown(.space) == [.touchBegin(slot: 0, x: 640, y: 720)])
    }

    @Test("An unbound key is not claimed, so it still reaches the guest keyboard")
    func unboundKeysPassThrough() {
        let mapper = InputMapper(
            profile: InputProfile(name: "Test", bindings: [fireButton(at: NormalizedPoint(x: 0.5, y: 0.5))]),
            guestSize: guestSize)
        #expect(mapper.handles(.space))
        #expect(!mapper.handles(.a))
    }

    @Test("Simultaneous buttons take separate touch slots, and free them on release")
    func concurrentButtonsUseDistinctSlots() {
        var mapper = InputMapper(profile: InputProfile(name: "Test", bindings: [
            fireButton(at: NormalizedPoint(x: 0.9, y: 0.8), key: .space),
            InputBinding(label: "Jump", trigger: .key(.j), action: .touch(NormalizedPoint(x: 0.7, y: 0.8))),
        ]), guestSize: guestSize)

        guard case let .touchBegin(first, _, _) = mapper.keyDown(.space).first else {
            Issue.record("expected a touch"); return
        }
        guard case let .touchBegin(second, _, _) = mapper.keyDown(.j).first else {
            Issue.record("expected a touch"); return
        }
        #expect(first != second)

        _ = mapper.keyUp(.space)
        // The freed slot is reused rather than leaked.
        guard case let .touchBegin(reused, _, _) = mapper.keyDown(.space).first else {
            Issue.record("expected a touch"); return
        }
        #expect(reused == first)
    }

    @Test("Running out of touch slots reports the binding rather than silently dropping it")
    func slotExhaustionIsReported() {
        let bindings = [LinuxKeyCode.a, .s, .d].enumerated().map { index, key in
            InputBinding(label: "Button \(index)", trigger: .key(key),
                         action: .touch(NormalizedPoint(x: 0.5, y: 0.5)))
        }
        var mapper = InputMapper(profile: InputProfile(name: "Test", bindings: bindings),
                                 guestSize: guestSize, maximumSlots: 2)
        #expect(!mapper.keyDown(.a).isEmpty)
        #expect(!mapper.keyDown(.s).isEmpty)
        #expect(mapper.keyDown(.d).isEmpty)

        let diagnostics = mapper.takeDiagnostics()
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].contains("Button 2"))
        #expect(mapper.takeDiagnostics().isEmpty)   // cleared once read
    }

    // MARK: - Virtual stick

    @Test("A stick begins at its centre before moving, so no finger teleports on")
    func stickBeginsAtCentre() {
        var mapper = InputMapper(profile: InputProfile(name: "Test", bindings: [
            moveStick(key: .d, direction: .right),
        ]), guestSize: guestSize)

        let events = mapper.keyDown(.d)
        #expect(events.count == 2)
        // Centre (0.2, 0.7) of 1920x1080 = (384, 756); throw 0.1 x 1080 = 108.
        #expect(events[0] == .touchBegin(slot: 0, x: 384, y: 756))
        #expect(events[1] == .touchUpdate(slot: 0, x: 492, y: 756))
    }

    @Test("Two directions on one stick combine into a diagonal, not two touches")
    func directionsCombineIntoOneStick() {
        var mapper = InputMapper(profile: InputProfile(name: "Test", bindings: [
            moveStick(key: .w, direction: .up),
            moveStick(key: .d, direction: .right),
        ]), guestSize: guestSize)

        _ = mapper.keyDown(.w)
        let diagonal = mapper.keyDown(.d)
        #expect(diagonal.count == 1)
        guard case let .touchUpdate(slot, x, y) = diagonal[0] else {
            Issue.record("expected an update on the existing stick"); return
        }
        #expect(slot == 0)   // still one finger

        // Clamped to the unit circle: a diagonal must not out-reach a cardinal.
        let centre = CGPoint(x: 384, y: 756)
        let reach = 0.1 * 1080.0
        let distance = ((x - Double(centre.x)) * (x - Double(centre.x))
                        + (y - Double(centre.y)) * (y - Double(centre.y))).squareRoot()
        #expect(abs(distance - reach) < 0.001)
    }

    @Test("Releasing every direction lifts the stick back to neutral")
    func stickReleasesWhenNeutral() {
        var mapper = InputMapper(profile: InputProfile(name: "Test", bindings: [
            moveStick(key: .w, direction: .up),
            moveStick(key: .d, direction: .right),
        ]), guestSize: guestSize)

        _ = mapper.keyDown(.w)
        _ = mapper.keyDown(.d)
        #expect(mapper.keyUp(.w).count == 1)          // still deflected right
        let final = mapper.keyUp(.d)
        #expect(final == [.touchEnd(slot: 0, x: 384, y: 756)])
    }

    @Test("The stick throw is measured against the shorter edge, so it stays circular")
    func stickThrowIsCircular() {
        var vertical = InputMapper(profile: InputProfile(name: "Test", bindings: [
            moveStick(key: .w, direction: .up, center: NormalizedPoint(x: 0.5, y: 0.5), radius: 0.1),
        ]), guestSize: CGSize(width: 2560, height: 1080))
        var horizontal = InputMapper(profile: InputProfile(name: "Test", bindings: [
            moveStick(key: .d, direction: .right, center: NormalizedPoint(x: 0.5, y: 0.5), radius: 0.1),
        ]), guestSize: CGSize(width: 2560, height: 1080))

        guard case let .touchUpdate(_, _, upY) = vertical.keyDown(.w).last,
              case let .touchUpdate(_, rightX, _) = horizontal.keyDown(.d).last else {
            Issue.record("expected stick updates"); return
        }
        // Both throws are 0.1 x 1080 = 108 px from the centre.
        #expect(abs((540 - upY) - 108) < 0.001)
        #expect(abs((rightX - 1280) - 108) < 0.001)
    }

    // MARK: - Gamepad

    @Test("A gamepad button becomes a touch, and only changes are emitted")
    func gamepadButtonBecomesTouch() {
        var mapper = InputMapper(profile: InputProfile(name: "Test", bindings: [
            InputBinding(label: "Fire", trigger: .gamepadButton(.a),
                         action: .touch(NormalizedPoint(x: 0.9, y: 0.8))),
        ]), guestSize: guestSize)

        #expect(mapper.apply(GamepadSnapshot(pressedButtons: [.a])) == [.touchBegin(slot: 0, x: 1728, y: 864)])
        // The same state again is not a new press.
        #expect(mapper.apply(GamepadSnapshot(pressedButtons: [.a])).isEmpty)
        #expect(mapper.apply(.neutral) == [.touchEnd(slot: 0, x: 1728, y: 864)])
    }

    @Test("An analog stick drives a virtual stick proportionally")
    func analogStickIsProportional() {
        var mapper = InputMapper(profile: InputProfile(name: "Test", bindings: [
            InputBinding(label: "Move", trigger: .gamepadStick(.left),
                         action: .stick(StickBinding(
                            stickID: "move", center: NormalizedPoint(x: 0.5, y: 0.5), radius: 0.2))),
        ]), guestSize: guestSize)

        // Half deflection right reaches half the throw.
        let events = mapper.apply(GamepadSnapshot(leftStick: CGPoint(x: 0.5, y: 0)))
        guard case let .touchUpdate(_, x, y) = events.last else {
            Issue.record("expected a stick update"); return
        }
        #expect(abs(x - (960 + 0.5 * 0.2 * 1080)) < 0.001)
        #expect(abs(y - 540) < 0.001)
    }

    @Test("Stick drift inside the deadzone is ignored")
    func deadzoneSuppressesDrift() {
        let drifting = GamepadSnapshot(leftStick: CGPoint(x: 0.03, y: -0.02))
        #expect(drifting.applyingDeadzone(0.15).leftStick == .zero)
        // A real push survives.
        let pushed = GamepadSnapshot(leftStick: CGPoint(x: 0.6, y: 0))
        #expect(pushed.applyingDeadzone(0.15).leftStick == CGPoint(x: 0.6, y: 0))
    }

    @Test("A gamepad button can send a key, which is how Back is reached")
    func gamepadButtonCanSendAKey() {
        var mapper = InputMapper(profile: InputProfile(name: "Test", bindings: [
            InputBinding(label: "Back", trigger: .gamepadButton(.b), action: .key(.escape)),
        ]), guestSize: guestSize)
        #expect(mapper.apply(GamepadSnapshot(pressedButtons: [.b])) == [.keyPress(.escape)])
        #expect(mapper.apply(.neutral) == [.keyRelease(.escape)])
    }

    // MARK: - Releasing

    @Test("releaseAll lifts every held touch and stick")
    func releaseAllLiftsEverything() {
        var mapper = InputMapper(profile: InputProfile(name: "Test", bindings: [
            fireButton(at: NormalizedPoint(x: 0.9, y: 0.8)),
            moveStick(key: .w, direction: .up),
        ]), guestSize: guestSize)

        _ = mapper.keyDown(.space)
        _ = mapper.keyDown(.w)
        let released = mapper.releaseAll()
        #expect(released.count == 2)
        #expect(released.allSatisfy { if case .touchEnd = $0 { return true } else { return false } })
        // Everything is forgotten, so the next press starts from slot 0 again.
        #expect(mapper.keyDown(.space) == [.touchBegin(slot: 0, x: 1728, y: 864)])
    }

    @Test("Swapping a profile lifts what the old one was holding")
    func profileSwapReleasesHeldInput() {
        var mapper = InputMapper(profile: InputProfile(name: "A", bindings: [
            fireButton(at: NormalizedPoint(x: 0.9, y: 0.8)),
        ]), guestSize: guestSize)
        _ = mapper.keyDown(.space)

        // Without this the guest keeps a finger down that nothing can ever lift.
        let released = mapper.replaceProfile(InputProfile(name: "B"))
        #expect(released == [.touchEnd(slot: 0, x: 1728, y: 864)])
        #expect(mapper.profile.name == "B")
        #expect(mapper.keyDown(.space).isEmpty)
    }

    // MARK: - Regressions found by review

    @Test("A key held through a gamepad button is released, not left down forever")
    func gamepadHeldKeyIsReleased() {
        // The release used to be derived from keys pressed on the *keyboard*, so
        // a key driven by a gamepad button was never in that set. Losing focus
        // left it held in the guest with nothing able to lift it.
        var mapper = InputMapper(profile: InputProfile(name: "Test", bindings: [
            InputBinding(label: "Back", trigger: .gamepadButton(.b), action: .key(.escape)),
        ]), guestSize: guestSize)

        #expect(mapper.apply(GamepadSnapshot(pressedButtons: [.b])) == [.keyPress(.escape)])
        #expect(mapper.releaseAll() == [.keyRelease(.escape)])
    }

    @Test("Two bindings on one trigger each get exactly one release")
    func duplicateTriggersEachRelease() {
        // Looking the binding up by trigger returned the first match, so the
        // second binding's key was pressed and never released.
        var mapper = InputMapper(profile: InputProfile(name: "Test", bindings: [
            InputBinding(label: "Touch", trigger: .key(.space),
                         action: .touch(NormalizedPoint(x: 0.5, y: 0.5))),
            InputBinding(label: "Enter", trigger: .key(.space), action: .key(.enter)),
        ]), guestSize: guestSize)

        let pressed = mapper.keyDown(.space)
        #expect(pressed.contains(.keyPress(.enter)))
        let released = mapper.releaseAll()
        #expect(released.filter { $0 == .keyRelease(.enter) }.count == 1)
    }

    @Test("Releasing everything does not re-fire a button still physically held")
    func releaseAllDoesNotRepressHeldButtons() {
        var mapper = InputMapper(profile: InputProfile(name: "Test", bindings: [
            InputBinding(label: "Fire", trigger: .gamepadButton(.a),
                         action: .touch(NormalizedPoint(x: 0.9, y: 0.8))),
        ]), guestSize: guestSize)

        let held = GamepadSnapshot(pressedButtons: [.a])
        _ = mapper.apply(held)
        _ = mapper.releaseAll()

        // The pad keeps reporting while the window is unfocused. A is still
        // down and has not changed, so it must not read as a new press.
        #expect(mapper.apply(held).isEmpty)
        // Letting go really does nothing further either.
        #expect(mapper.apply(.neutral).isEmpty)
    }

    @Test("Opposing directions hold the stick at its centre instead of lifting it")
    func opposingDirectionsHoldAtCentre() {
        var mapper = InputMapper(profile: InputProfile(name: "Test", bindings: [
            moveStick(key: .a, direction: .left),
            moveStick(key: .d, direction: .right),
        ]), guestSize: guestSize)

        _ = mapper.keyDown(.a)
        // Both held: the vector cancels, but a finger is still on the stick.
        let cancelled = mapper.keyDown(.d)
        #expect(cancelled == [.touchUpdate(slot: 0, x: 384, y: 756)])
        #expect(!cancelled.contains { if case .touchEnd = $0 { return true } else { return false } })

        // Releasing one leaves it deflected the other way, still the same finger.
        let stillHeld = mapper.keyUp(.a)
        #expect(stillHeld == [.touchUpdate(slot: 0, x: 492, y: 756)])
        // Only when nothing is held does it lift.
        #expect(mapper.keyUp(.d) == [.touchEnd(slot: 0, x: 384, y: 756)])
    }

    @Test("A stick near an edge is clamped to the display")
    func stickTargetIsClamped() {
        // Centre hard against the right edge with a generous throw: an unclamped
        // target lands off-screen, where the guest ignores it.
        var mapper = InputMapper(profile: InputProfile(name: "Test", bindings: [
            moveStick(key: .d, direction: .right,
                      center: NormalizedPoint(x: 0.98, y: 0.5), radius: 0.3),
        ]), guestSize: guestSize)

        guard case let .touchUpdate(_, x, y) = mapper.keyDown(.d).last else {
            Issue.record("expected a stick update"); return
        }
        #expect(x <= Double(guestSize.width))
        #expect(y >= 0 && y <= Double(guestSize.height))
    }

    // MARK: - Profile validation

    @Test("A profile reports bindings that fight each other or fall off the screen")
    func profileProblemsAreReported() {
        let profile = InputProfile(name: "Broken", bindings: [
            InputBinding(label: "Fire", trigger: .key(.space), action: .touch(NormalizedPoint(x: 0.5, y: 0.5))),
            InputBinding(label: "Also fire", trigger: .key(.space), action: .touch(NormalizedPoint(x: 0.2, y: 0.2))),
            InputBinding(label: "Off screen", trigger: .key(.a), action: .touch(NormalizedPoint(x: 1.4, y: 0.5))),
            InputBinding(label: "No direction", trigger: .key(.b), action: .stick(
                StickBinding(stickID: "move", center: NormalizedPoint(x: 0.2, y: 0.7)))),
        ])
        let problems = profile.problems()
        #expect(problems.contains { $0.contains("same control") })
        #expect(problems.contains { $0.contains("off the screen") })
        #expect(problems.contains { $0.contains("no direction") })
    }

    @Test("Bindings that disagree about one stick are reported")
    func inconsistentStickGeometryIsReported() {
        // They describe one control, so a disagreement means the touch that
        // lifts the stick ends somewhere the touch that began it never was.
        let profile = InputProfile(name: "Inconsistent", bindings: [
            InputBinding(label: "Up", trigger: .key(.w), action: .stick(StickBinding(
                stickID: "move", center: NormalizedPoint(x: 0.2, y: 0.7), direction: .up))),
            InputBinding(label: "Down", trigger: .key(.s), action: .stick(StickBinding(
                stickID: "move", center: NormalizedPoint(x: 0.6, y: 0.7), direction: .down))),
        ])
        #expect(profile.problems().contains { $0.contains("place it") })
    }

    @Test("Two analog controls on one stick are reported")
    func duplicateAnalogStickIsReported() {
        let profile = InputProfile(name: "Two sticks", bindings: [
            InputBinding(label: "Left pad", trigger: .gamepadStick(.left), action: .stick(
                StickBinding(stickID: "move", center: NormalizedPoint(x: 0.2, y: 0.7)))),
            InputBinding(label: "Right pad", trigger: .gamepadStick(.right), action: .stick(
                StickBinding(stickID: "move", center: NormalizedPoint(x: 0.2, y: 0.7)))),
        ])
        #expect(profile.problems().contains { $0.contains("only one of them can") })
    }

    @Test("A well-formed profile reports nothing")
    func validProfileIsSilent() {
        let profile = InputProfile(name: "Good", bindings: [
            fireButton(at: NormalizedPoint(x: 0.9, y: 0.8)),
            moveStick(key: .w, direction: .up),
            moveStick(key: .s, direction: .down),
            // Same centre AND same throw as the key bindings above: they are one
            // control, so they have to agree about where it is.
            InputBinding(label: "Move", trigger: .gamepadStick(.left), action: .stick(
                StickBinding(stickID: "move", center: NormalizedPoint(x: 0.2, y: 0.7), radius: 0.1))),
        ])
        #expect(profile.problems().isEmpty)
    }

    @Test("A profile survives a round trip through JSON")
    func profileRoundTrips() throws {
        let profile = InputProfile(name: "Round trip", bindings: [
            fireButton(at: NormalizedPoint(x: 0.9, y: 0.8)),
            moveStick(key: .w, direction: .up),
            InputBinding(label: "Back", trigger: .gamepadButton(.b), action: .key(.escape)),
            InputBinding(label: "Move", trigger: .gamepadStick(.left), action: .stick(
                StickBinding(stickID: "move", center: NormalizedPoint(x: 0.2, y: 0.7)))),
        ])
        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(InputProfile.self, from: data) == profile)
    }
}
