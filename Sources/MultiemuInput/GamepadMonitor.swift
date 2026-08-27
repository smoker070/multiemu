import CoreGraphics
import Foundation
import GameController

/// Watches for game controllers and reports their state as `GamepadSnapshot`.
///
/// Deliberately thin. Everything that decides *what a press means* lives in
/// `InputMapper`, which is a pure value type — so the part of gamepad support
/// that can be tested without hardware is nearly all of it, and this adapter is
/// small enough to read.
///
/// The element names below were read off the running system rather than
/// recalled: see `docs/VERIFY.md` → `GAMECONTROLLER-ELEMENTS`.
@MainActor
public final class GamepadMonitor {

    /// Called whenever the gamepad's state changes.
    public var onChange: ((GamepadSnapshot) -> Void)?
    /// Called when a controller connects or disconnects.
    public var onAvailabilityChange: ((String?) -> Void)?

    /// Ignores stick drift around centre. A resting stick otherwise produces a
    /// continuous dribble of touch updates.
    public var deadzone: Double = 0.15

    public private(set) var connectedControllerName: String?
    public var isConnected: Bool { connectedControllerName != nil }

    /// Notification tokens, held outside the actor so `deinit` can release them.
    /// `NotificationCenter.removeObserver` is safe from any thread.
    private final class ObserverTokens: @unchecked Sendable {
        var tokens: [NSObjectProtocol] = []
        func removeAll() {
            for token in tokens { NotificationCenter.default.removeObserver(token) }
            tokens.removeAll()
        }
        deinit { removeAll() }
    }

    private let observers = ObserverTokens()
    /// The controller whose handler this monitor installed, so it can be taken
    /// back off again. `valueChangedHandler` is a single slot on a shared
    /// object: leaving one installed means a monitor that has stopped still
    /// drives whatever it captured.
    private weak var adopted: GCController?

    public init() {}

    public func start() {
        let center = NotificationCenter.default
        // Both notifications re-read the controller list rather than trusting
        // `notification.object`: the list is the authority on what is attached
        // now, and it avoids carrying a non-Sendable value across actors.
        for name in [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.adopt(GCController.controllers().first) }
            })
        }
        adopt(GCController.controllers().first)
    }

    public func stop() {
        adopted?.extendedGamepad?.valueChangedHandler = nil
        adopted = nil
        observers.removeAll()
        connectedControllerName = nil
        onAvailabilityChange?(nil)
    }

    private func adopt(_ controller: GCController?) {
        if let previous = adopted, previous !== controller {
            previous.extendedGamepad?.valueChangedHandler = nil
        }
        adopted = controller
        guard let gamepad = controller?.extendedGamepad else {
            connectedControllerName = nil
            onAvailabilityChange?(nil)
            // Anything the departing controller was holding must be lifted, or
            // the guest keeps a finger down that nothing can raise.
            onChange?(.neutral)
            return
        }
        connectedControllerName = controller?.vendorName ?? "Game controller"
        onAvailabilityChange?(connectedControllerName)

        gamepad.valueChangedHandler = { [weak self] pad, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onChange?(Self.snapshot(of: pad).applyingDeadzone(self.deadzone))
            }
        }
        onChange?(Self.snapshot(of: gamepad).applyingDeadzone(deadzone))
    }

    /// Reads a whole gamepad into a value.
    ///
    /// `static` and taking the gamepad as a parameter so the mapping from
    /// element to button is inspectable on its own.
    static func snapshot(of pad: GCExtendedGamepad) -> GamepadSnapshot {
        var pressed: Set<GamepadButton> = []
        func add(_ button: GamepadButton, _ input: GCControllerButtonInput?) {
            if input?.isPressed == true { pressed.insert(button) }
        }
        add(.a, pad.buttonA)
        add(.b, pad.buttonB)
        add(.x, pad.buttonX)
        add(.y, pad.buttonY)
        add(.leftShoulder, pad.leftShoulder)
        add(.rightShoulder, pad.rightShoulder)
        add(.leftTrigger, pad.leftTrigger)
        add(.rightTrigger, pad.rightTrigger)
        add(.leftThumbstickButton, pad.leftThumbstickButton)
        add(.rightThumbstickButton, pad.rightThumbstickButton)
        add(.dpadUp, pad.dpad.up)
        add(.dpadDown, pad.dpad.down)
        add(.dpadLeft, pad.dpad.left)
        add(.dpadRight, pad.dpad.right)
        add(.menu, pad.buttonMenu)
        add(.options, pad.buttonOptions)
        add(.home, pad.buttonHome)

        // GameController reports y positive UPWARDS; screen space is positive
        // downwards. Getting this wrong inverts every vertical movement, which
        // looks like a working mapping until someone tries to walk forward.
        return GamepadSnapshot(
            pressedButtons: pressed,
            leftStick: CGPoint(x: Double(pad.leftThumbstick.xAxis.value),
                               y: Double(-pad.leftThumbstick.yAxis.value)),
            rightStick: CGPoint(x: Double(pad.rightThumbstick.xAxis.value),
                                y: Double(-pad.rightThumbstick.yAxis.value))
        )
    }
}
