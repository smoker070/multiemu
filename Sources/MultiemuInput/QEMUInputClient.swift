import CoreGraphics
import Foundation
import MultiemuDBus
import MultiemuSupport

/// Sends input to the guest over QEMU's D-Bus display interfaces.
///
/// Signatures are taken verbatim from QEMU's own introspection XML rather than
/// from documentation:
///
/// ```
/// org.qemu.Display1.Keyboard    Press(u) Release(u)
/// org.qemu.Display1.Mouse       Press(u) Release(u) SetAbsPosition(uu) RelMotion(ii)
/// org.qemu.Display1.MultiTouch  SendEvent(utdd)
/// org.qemu.Display1.Console     SetUIInfo(qqiiuu)
/// ```
public actor QEMUInputClient {

    public static let keyboardInterface = "org.qemu.Display1.Keyboard"
    public static let mouseInterface = "org.qemu.Display1.Mouse"
    public static let multiTouchInterface = "org.qemu.Display1.MultiTouch"
    public static let consoleInterface = "org.qemu.Display1.Console"

    private let connection: DBusConnection
    private let consolePath: String
    /// Keys currently held, so a lost focus or a torn-down session can release
    /// them. A key left pressed in the guest repeats forever and looks like a
    /// hung emulator.
    private var heldKeys: Set<UInt32> = []
    private var heldButtons: Set<UInt32> = []
    /// Cached `Mouse.IsAbsolute`. The pointer device kind decides which motion
    /// method is legal, and QEMU rejects the wrong one outright.
    private var pointerIsAbsolute: Bool?
    /// Last position sent, used to synthesise deltas for a relative device.
    private var lastPointerPosition: CGPoint = .zero

    public init(connection: DBusConnection, consolePath: String = "/org/qemu/Display1/Console_0") {
        self.connection = connection
        self.consolePath = consolePath
    }

    // MARK: - Keyboard

    public func press(_ key: LinuxKeyCode) async throws {
        try await send(keyboard: "Press", key.rawValue)
        heldKeys.insert(key.rawValue)
    }

    public func release(_ key: LinuxKeyCode) async throws {
        try await send(keyboard: "Release", key.rawValue)
        heldKeys.remove(key.rawValue)
    }

    /// Press then release.
    public func tap(_ key: LinuxKeyCode) async throws {
        try await press(key)
        try await release(key)
    }

    /// Types US-ASCII text, holding Shift where the character needs it.
    public func type(_ text: String) async throws {
        for character in text {
            guard let stroke = MacKeyboardMap.keyStroke(for: character) else {
                MultiemuLog.input.error("No key mapping for character \(String(character), privacy: .public)")
                continue
            }
            if stroke.shift { try await press(.leftShift) }
            try await tap(stroke.key)
            if stroke.shift { try await release(.leftShift) }
        }
    }

    /// Releases everything currently held.
    ///
    /// Called when the display view loses focus or a session ends. Without it a
    /// modifier held while switching away stays down in the guest.
    public func releaseAll() async {
        for key in heldKeys {
            try? await send(keyboard: "Release", key)
        }
        heldKeys.removeAll()
        for button in heldButtons {
            try? await send(mouse: "Release", [.uint32(button)])
        }
        heldButtons.removeAll()
    }

    // MARK: - Capabilities

    /// Reads a property through `org.freedesktop.DBus.Properties`.
    public func property(_ name: String, on interface: String) async throws -> DBusValue? {
        let reply = try await connection.call(
            path: consolePath,
            interface: "org.freedesktop.DBus.Properties",
            member: "Get",
            body: [.string(interface), .string(name)]
        )
        guard case .variant(let value)? = reply.body.first else { return reply.body.first }
        return value
    }

    /// Whether the guest's pointing device reports absolute coordinates.
    ///
    /// A tablet is absolute and a mouse is relative, and QEMU refuses the wrong
    /// call rather than adapting: sending `RelMotion` to an absolute device
    /// fails with `org.qemu.Display1.Error.Invalid: Mouse is not relative`.
    /// Cached because it cannot change for the life of a device.
    public func isPointerAbsolute() async -> Bool {
        if let pointerIsAbsolute { return pointerIsAbsolute }
        let value = try? await property("IsAbsolute", on: Self.mouseInterface)
        // Absolute is the safer default: an absolute device is what a virtual
        // tablet provides, and it is what a touch-first Android guest wants.
        let resolved = value?.boolValue ?? true
        pointerIsAbsolute = resolved
        return resolved
    }

    /// Currently held modifier bitmask, as QEMU sees it.
    public func keyboardModifiers() async -> UInt32 {
        (try? await property("Modifiers", on: Self.keyboardInterface))??.uint32Value ?? 0
    }

    /// Number of simultaneous touch points the guest device supports.
    public func maxTouchSlots() async -> Int {
        Int((try? await property("MaxSlots", on: Self.multiTouchInterface))??.int32Value ?? 0)
    }

    /// The console's current geometry, without waiting for a scanout.
    public func consoleGeometry() async -> CGSize? {
        guard let width = (try? await property("Width", on: Self.consoleInterface))??.uint32Value,
              let height = (try? await property("Height", on: Self.consoleInterface))??.uint32Value else {
            return nil
        }
        return CGSize(width: Int(width), height: Int(height))
    }

    // MARK: - Pointer

    public func press(_ button: QEMUPointerButton) async throws {
        try await send(mouse: "Press", [.uint32(button.rawValue)])
        heldButtons.insert(button.rawValue)
    }

    public func release(_ button: QEMUPointerButton) async throws {
        try await send(mouse: "Release", [.uint32(button.rawValue)])
        heldButtons.remove(button.rawValue)
    }

    public func click(_ button: QEMUPointerButton = .left) async throws {
        try await press(button)
        try await release(button)
    }

    /// Moves the pointer to a guest pixel, using whichever motion method the
    /// guest's device accepts.
    ///
    /// This is what callers should use. For a relative device the movement is
    /// synthesised as a delta from the last position, so the same call site
    /// works for both kinds.
    public func move(to point: CGPoint) async throws {
        if await isPointerAbsolute() {
            try await moveAbsolute(to: point)
        } else {
            try await moveRelative(
                dx: Int32(point.x - lastPointerPosition.x),
                dy: Int32(point.y - lastPointerPosition.y)
            )
        }
        lastPointerPosition = point
    }

    /// Moves the pointer to a guest framebuffer pixel.
    ///
    /// Coordinates are in guest pixels, which is what QEMU's implementation
    /// expects — it forwards them with the surface dimensions as the axis range.
    /// Fails on a relative device; prefer `move(to:)`.
    public func moveAbsolute(to point: CGPoint) async throws {
        try await send(mouse: "SetAbsPosition", [
            .uint32(UInt32(max(0, point.x))),
            .uint32(UInt32(max(0, point.y))),
        ])
        lastPointerPosition = point
    }

    /// Fails on an absolute device; prefer `move(to:)`.
    public func moveRelative(dx: Int32, dy: Int32) async throws {
        try await send(mouse: "RelMotion", [.int32(dx), .int32(dy)])
    }

    /// Scrolls by emitting wheel button events, which is how QEMU models it.
    public func scroll(lines: Int) async throws {
        let button: QEMUPointerButton = lines > 0 ? .wheelUp : .wheelDown
        for _ in 0..<abs(lines) { try await click(button) }
    }

    // MARK: - Touch

    /// Sends a multi-touch event. `x` and `y` are guest pixels.
    public func touch(
        _ kind: QEMUMultiTouchKind,
        slot: UInt64 = 0,
        x: Double,
        y: Double
    ) async throws {
        try await connection.call(
            path: consolePath, interface: Self.multiTouchInterface, member: "SendEvent",
            body: [.uint32(kind.rawValue), .uint64(slot), .double(x), .double(y)]
        )
    }

    /// A complete tap: begin, then end at the same point.
    public func tapTouch(at point: CGPoint, slot: UInt64 = 0) async throws {
        try await touch(.begin, slot: slot, x: Double(point.x), y: Double(point.y))
        try await touch(.end, slot: slot, x: Double(point.x), y: Double(point.y))
    }

    // MARK: - Console

    /// Tells the guest the size of the display area.
    ///
    /// Android and Linux use this to pick a mode, so it is how the window size
    /// eventually drives the guest's resolution in Milestone 12 — while still
    /// leaving the guest in charge of what its resolution actually is.
    public func setUIInfo(
        widthMillimetres: UInt16 = 0,
        heightMillimetres: UInt16 = 0,
        xOffset: Int32 = 0,
        yOffset: Int32 = 0,
        width: UInt32,
        height: UInt32
    ) async throws {
        try await connection.call(
            path: consolePath, interface: Self.consoleInterface, member: "SetUIInfo",
            body: [
                .uint16(widthMillimetres), .uint16(heightMillimetres),
                .int32(xOffset), .int32(yOffset),
                .uint32(width), .uint32(height),
            ]
        )
    }

    // MARK: - Plumbing

    private func send(keyboard member: String, _ keycode: UInt32) async throws {
        try await connection.call(
            path: consolePath, interface: Self.keyboardInterface,
            member: member, body: [.uint32(keycode)]
        )
    }

    private func send(mouse member: String, _ body: [DBusValue]) async throws {
        try await connection.call(
            path: consolePath, interface: Self.mouseInterface, member: member, body: body
        )
    }
}
