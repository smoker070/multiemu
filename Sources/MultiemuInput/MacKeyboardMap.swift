import Foundation

/// Translates macOS virtual key codes into Linux evdev codes.
///
/// macOS virtual key codes are positional and famously unordered — `A` is 0 and
/// `S` is 1 — so this is a lookup table, not an arithmetic conversion. Values
/// are the Carbon `kVK_*` constants.
public enum MacKeyboardMap {

    /// macOS virtual key code → Linux evdev code.
    public static let virtualKeyToLinux: [UInt16: LinuxKeyCode] = [
        0x00: .a, 0x01: .s, 0x02: .d, 0x03: .f, 0x04: .h, 0x05: .g,
        0x06: .z, 0x07: .x, 0x08: .c, 0x09: .v, 0x0B: .b, 0x0C: .q,
        0x0D: .w, 0x0E: .e, 0x0F: .r, 0x10: .y, 0x11: .t,
        0x12: .one, 0x13: .two, 0x14: .three, 0x15: .four,
        0x16: .six, 0x17: .five, 0x18: .equal, 0x19: .nine, 0x1A: .seven,
        0x1B: .minus, 0x1C: .eight, 0x1D: .zero,
        0x1E: .rightBracket, 0x1F: .o, 0x20: .u, 0x21: .leftBracket,
        0x22: .i, 0x23: .p, 0x24: .enter, 0x25: .l, 0x26: .j,
        0x27: .apostrophe, 0x28: .k, 0x29: .semicolon, 0x2A: .backslash,
        0x2B: .comma, 0x2C: .slash, 0x2D: .n, 0x2E: .m, 0x2F: .dot,
        0x30: .tab, 0x31: .space, 0x32: .grave, 0x33: .backspace, 0x35: .escape,
        // Modifiers. macOS Command maps to the guest's Meta/Super key, which is
        // what Android and Linux expect for that physical position.
        0x37: .leftMeta, 0x38: .leftShift, 0x39: .capsLock,
        0x3A: .leftAlt, 0x3B: .leftControl,
        0x3C: .rightShift, 0x3D: .rightAlt, 0x3E: .rightControl, 0x36: .rightMeta,
        // Function keys, in macOS's non-sequential order.
        0x7A: .f1, 0x78: .f2, 0x63: .f3, 0x76: .f4, 0x60: .f5, 0x61: .f6,
        0x62: .f7, 0x64: .f8, 0x65: .f9, 0x6D: .f10, 0x67: .f11, 0x6F: .f12,
        // Navigation. These are the codes where Linux evdev and AT set-1
        // scancodes diverge, so they are the ones to check first if a key
        // misbehaves. See docs/VERIFY.md → QEMU-DBUS-KEYCODE-ENCODING.
        0x73: .home, 0x74: .pageUp, 0x75: .delete, 0x77: .end, 0x79: .pageDown,
        0x7B: .left, 0x7C: .right, 0x7D: .down, 0x7E: .up,
    ]

    public static func linuxKey(forVirtualKey code: UInt16) -> LinuxKeyCode? {
        virtualKeyToLinux[code]
    }

    /// A character as a key press plus whether Shift is required.
    ///
    /// Used for typing text programmatically — automated verification, and the
    /// paste path later. Covers US-ASCII only; a full keyboard-layout-aware
    /// path belongs with the keymap work in Milestone 16.
    public static func keyStroke(for character: Character) -> (key: LinuxKeyCode, shift: Bool)? {
        if let unshifted = unshiftedCharacters[character] { return (unshifted, false) }
        if let shifted = shiftedCharacters[character] { return (shifted, true) }
        return nil
    }

    private static let unshiftedCharacters: [Character: LinuxKeyCode] = [
        "a": .a, "b": .b, "c": .c, "d": .d, "e": .e, "f": .f, "g": .g, "h": .h,
        "i": .i, "j": .j, "k": .k, "l": .l, "m": .m, "n": .n, "o": .o, "p": .p,
        "q": .q, "r": .r, "s": .s, "t": .t, "u": .u, "v": .v, "w": .w, "x": .x,
        "y": .y, "z": .z,
        "1": .one, "2": .two, "3": .three, "4": .four, "5": .five,
        "6": .six, "7": .seven, "8": .eight, "9": .nine, "0": .zero,
        "-": .minus, "=": .equal, "[": .leftBracket, "]": .rightBracket,
        "\\": .backslash, ";": .semicolon, "'": .apostrophe, "`": .grave,
        ",": .comma, ".": .dot, "/": .slash, " ": .space,
        "\n": .enter, "\t": .tab,
    ]

    private static let shiftedCharacters: [Character: LinuxKeyCode] = [
        "A": .a, "B": .b, "C": .c, "D": .d, "E": .e, "F": .f, "G": .g, "H": .h,
        "I": .i, "J": .j, "K": .k, "L": .l, "M": .m, "N": .n, "O": .o, "P": .p,
        "Q": .q, "R": .r, "S": .s, "T": .t, "U": .u, "V": .v, "W": .w, "X": .x,
        "Y": .y, "Z": .z,
        "!": .one, "@": .two, "#": .three, "$": .four, "%": .five,
        "^": .six, "&": .seven, "*": .eight, "(": .nine, ")": .zero,
        "_": .minus, "+": .equal, "{": .leftBracket, "}": .rightBracket,
        "|": .backslash, ":": .semicolon, "\"": .apostrophe, "~": .grave,
        "<": .comma, ">": .dot, "?": .slash,
    ]
}
