import Foundation

/// HID usage tables for the keycodes this board can produce.
///
/// ZMK packs a binding parameter as `(usage_page << 16) | usage_id`, confirmed
/// against live hardware: the first key of the M0110A layout reports 458805 =
/// 0x00070035: page 0x07 (Keyboard/Keypad), usage 0x35 (Grave).
enum HIDKeycodes {
    static let keyboardPage: UInt32 = 0x07
    /// Consumer page. ZMK's `C_*` codes live here (volume, transport, screen
    /// brightness), and the keymap's Fn layer uses several of them.
    static let consumerPage: UInt32 = 0x0C

    static func encode(page: UInt32 = keyboardPage, usage: UInt32) -> UInt32 {
        (page << 16) | usage
    }

    static func decode(_ param: UInt32) -> (page: UInt32, usage: UInt32) {
        (param >> 16, param & 0xFFFF)
    }

    /// Short label for a binding parameter, suitable for drawing on a keycap.
    ///
    /// Both pages the keymap actually uses are decoded. Falling through to raw
    /// hex for anything off the keyboard page put `0xc00ea` on a keycap where
    /// the board has a volume key.
    static func label(for param: UInt32) -> String {
        let (page, usage) = decode(param)
        switch page {
        case keyboardPage: return keyboard[usage] ?? "0x\(String(usage, radix: 16))"
        case consumerPage: return consumer[usage] ?? "0x\(String(usage, radix: 16))"
        default: return "0x\(String(param, radix: 16))"
        }
    }

    /// Longer name for menus and pickers.
    static func name(for param: UInt32) -> String {
        let (page, usage) = decode(param)
        switch page {
        case keyboardPage: return keyboardNames[usage] ?? label(for: param)
        case consumerPage: return consumerNames[usage] ?? label(for: param)
        default: return "page \(page) usage \(usage)"
        }
    }

    /// Consumer-page usage -> keycap label. Named for ZMK's `C_*` bindings, so
    /// `C_VOL_UP` is `0xE9` and so on.
    static let consumer: [UInt32: String] = [
        0x30: "power", 0x32: "sleep",
        0x6F: "bri+", 0x70: "bri-",
        0xB0: "play", 0xB1: "pause", 0xB3: "ff", 0xB4: "rw",
        0xB5: "next", 0xB6: "prev", 0xB7: "stop", 0xB8: "eject",
        0xCD: "play", 0xE2: "mute", 0xE9: "vol+", 0xEA: "vol-",
        0x183: "media", 0x18A: "mail", 0x192: "calc", 0x194: "files",
        0x19E: "lock",
        0x221: "search", 0x223: "home", 0x224: "back", 0x225: "fwd",
        0x226: "stop", 0x227: "reload",
    ]

    static let consumerNames: [UInt32: String] = [
        0x30: "Power", 0x32: "Sleep",
        0x6F: "Brightness Up", 0x70: "Brightness Down",
        0xB0: "Play", 0xB1: "Pause", 0xB3: "Fast Forward", 0xB4: "Rewind",
        0xB5: "Next Track", 0xB6: "Previous Track", 0xB7: "Stop", 0xB8: "Eject",
        0xCD: "Play/Pause", 0xE2: "Mute", 0xE9: "Volume Up", 0xEA: "Volume Down",
        0x183: "Media Player", 0x18A: "Mail", 0x192: "Calculator",
        0x194: "File Browser", 0x19E: "Lock Screen",
        0x221: "Search", 0x223: "Home", 0x224: "Back", 0x225: "Forward",
        0x226: "Stop Loading", 0x227: "Reload",
    ]

    /// usage id -> keycap label
    static let keyboard: [UInt32: String] = {
        var m: [UInt32: String] = [:]
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() {
            m[0x04 + UInt32(i)] = String(c)
        }
        for (i, c) in "1234567890".enumerated() {
            m[0x1E + UInt32(i)] = String(c)
        }
        for i in 0..<12 { m[0x3A + UInt32(i)] = "F\(i + 1)" }
        for i in 0..<9 { m[0x59 + UInt32(i)] = "\(i + 1)" }   // keypad 1-9
        m[0x62] = "0"                                          // keypad 0
        let fixed: [UInt32: String] = [
            0x28: "return", 0x29: "esc", 0x2A: "delete", 0x2B: "tab", 0x2C: "space",
            0x2D: "-", 0x2E: "=", 0x2F: "[", 0x30: "]", 0x31: "\\",
            0x33: ";", 0x34: "'", 0x35: "`", 0x36: ",", 0x37: ".", 0x38: "/",
            0x39: "caps", 0x64: "\\",
            0x46: "prtsc", 0x47: "sclk", 0x48: "pause",
            0x49: "ins", 0x4A: "home", 0x4B: "pgup", 0x4C: "del", 0x4D: "end", 0x4E: "pgdn",
            0x4F: "→", 0x50: "←", 0x51: "↓", 0x52: "↑",
            0x53: "clear", 0x54: "/", 0x55: "*", 0x56: "-", 0x57: "+",
            0x58: "enter", 0x63: ".", 0x67: "=",
            0xE0: "ctrl", 0xE1: "shift", 0xE2: "opt", 0xE3: "cmd",
            0xE4: "ctrl", 0xE5: "shift", 0xE6: "opt", 0xE7: "cmd",
        ]
        m.merge(fixed) { _, new in new }
        return m
    }()

    static let keyboardNames: [UInt32: String] = [
        0x28: "Return", 0x29: "Escape", 0x2A: "Backspace", 0x2B: "Tab", 0x2C: "Space",
        0x2D: "Minus", 0x2E: "Equal", 0x2F: "Left Bracket", 0x30: "Right Bracket",
        0x31: "Backslash", 0x33: "Semicolon", 0x34: "Apostrophe", 0x35: "Grave",
        0x36: "Comma", 0x37: "Period", 0x38: "Slash", 0x39: "Caps Lock",
        0x64: "Non-US Backslash",
        0x49: "Insert", 0x4A: "Home", 0x4B: "Page Up", 0x4C: "Delete Forward",
        0x4D: "End", 0x4E: "Page Down",
        0x4F: "Right Arrow", 0x50: "Left Arrow", 0x51: "Down Arrow", 0x52: "Up Arrow",
        0x53: "Keypad Clear", 0x54: "Keypad Divide", 0x55: "Keypad Multiply",
        0x56: "Keypad Minus", 0x57: "Keypad Plus", 0x58: "Keypad Enter",
        0x63: "Keypad Period", 0x67: "Keypad Equal",
        0xE0: "Left Control", 0xE1: "Left Shift", 0xE2: "Left Option", 0xE3: "Left Command",
        0xE4: "Right Control", 0xE5: "Right Shift", 0xE6: "Right Option", 0xE7: "Right Command",
    ]

    /// Grouped picker contents, in the order a person would look for them.
    static let groups: [(String, [UInt32])] = [
        ("Letters", Array(0x04...0x1D)),
        ("Numbers", Array(0x1E...0x27)),
        ("Punctuation", [0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x64]),
        ("Editing", [0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x39]),
        ("Navigation", [0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51, 0x52]),
        ("Function", Array(0x3A...0x45)),
        ("Keypad", [0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x5B, 0x5C, 0x5D,
                    0x5E, 0x5F, 0x60, 0x61, 0x62, 0x63, 0x67]),
        ("Modifiers", [0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7]),
    ]
}
