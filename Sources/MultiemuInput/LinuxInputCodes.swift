import Foundation

/// Linux evdev key codes, as `org.qemu.Display1.Keyboard.Press` expects.
///
/// QEMU maps the incoming number through `qemu_input_key_number_to_qcode`. For
/// the main keyboard block, Linux evdev codes and AT set-1 scancodes coincide
/// — Linux derived its codes from that set — so `A` is 30 either way. The
/// extended block (arrows, navigation) is where the two diverge, and those are
/// marked below as needing separate confirmation.
///
/// See `docs/VERIFY.md` → `QEMU-DBUS-KEYCODE-ENCODING`.
public enum LinuxKeyCode: UInt32, Sendable, Codable, CaseIterable {
    case escape = 1
    case one = 2, two = 3, three = 4, four = 5, five = 6
    case six = 7, seven = 8, eight = 9, nine = 10, zero = 11
    case minus = 12, equal = 13, backspace = 14, tab = 15
    case q = 16, w = 17, e = 18, r = 19, t = 20
    case y = 21, u = 22, i = 23, o = 24, p = 25
    case leftBracket = 26, rightBracket = 27, enter = 28, leftControl = 29
    case a = 30, s = 31, d = 32, f = 33, g = 34
    case h = 35, j = 36, k = 37, l = 38
    case semicolon = 39, apostrophe = 40, grave = 41, leftShift = 42, backslash = 43
    case z = 44, x = 45, c = 46, v = 47, b = 48
    case n = 49, m = 50, comma = 51, dot = 52, slash = 53
    case rightShift = 54, keypadAsterisk = 55, leftAlt = 56, space = 57, capsLock = 58
    case f1 = 59, f2 = 60, f3 = 61, f4 = 62, f5 = 63, f6 = 64
    case f7 = 65, f8 = 66, f9 = 67, f10 = 68
    case f11 = 87, f12 = 88
    case rightControl = 97, rightAlt = 100
    case home = 102, up = 103, pageUp = 104, left = 105, right = 106
    case end = 107, down = 108, pageDown = 109, insert = 110, delete = 111
    case leftMeta = 125, rightMeta = 126
}

/// Buttons as `org.qemu.Display1.Mouse.Press` expects them.
///
/// These are QEMU's own `InputButton` enum ordinals from `qapi/ui.json`, not
/// Linux `BTN_*` constants — a distinction that matters, because `BTN_LEFT` is
/// `0x110` and would be read here as an out-of-range button.
public enum QEMUPointerButton: UInt32, Sendable, CaseIterable {
    case left = 0
    case middle = 1
    case right = 2
    case wheelUp = 3
    case wheelDown = 4
    case side = 5
    case extra = 6
    case wheelLeft = 7
    case wheelRight = 8
}

/// `org.qemu.Display1.MultiTouch.SendEvent` event kinds.
///
/// Ordinals of QEMU's `InputMultiTouchType` (`qapi/ui.json`).
public enum QEMUMultiTouchKind: UInt32, Sendable {
    case begin = 0
    case update = 1
    case cancel = 2
    case end = 3
}
