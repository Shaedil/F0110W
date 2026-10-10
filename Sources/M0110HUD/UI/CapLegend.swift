import Foundation

/// How an M0110 keycap is printed. A word (`Tab`, `Shift`) sits small in the
/// top-left corner, a pair puts the shifted glyph above the base one, a single
/// letter is centered and larger, and the spacebar is blank.
///
/// Legends come from the HID usage, so a rebound cap shows its new legend.
enum CapLegend: Equatable {
    case blank
    case single(String)
    case pair(shifted: String, base: String)
    case word(String)

    /// The US ANSI shifted glyph for a usage, where the cap carries two.
    private static let shiftedGlyphs: [UInt32: String] = [
        0x1E: "!", 0x1F: "@", 0x20: "#", 0x21: "$", 0x22: "%",
        0x23: "^", 0x24: "&", 0x25: "*", 0x26: "(", 0x27: ")",
        0x2D: "_", 0x2E: "+", 0x2F: "{", 0x30: "}", 0x31: "|",
        0x33: ":", 0x34: "\"", 0x35: "~", 0x36: "<", 0x37: ">", 0x38: "?",
        0x64: "|",
    ]

    /// Words as printed on the board. The delete key says `Backspace`, and
    /// Command shows only the looped square.
    private static let printedWords: [UInt32: String] = [
        0x28: "Return", 0x29: "Esc", 0x2A: "Backspace", 0x2B: "Tab",
        0x39: "Caps Lock", 0x58: "Enter",
        0xE0: "Control", 0xE1: "Shift", 0xE2: "Option", 0xE3: "\u{2318}",
        0xE4: "Control", 0xE5: "Shift", 0xE6: "Option", 0xE7: "\u{2318}",
    ]

    private static let spaceUsage: UInt32 = 0x2C

    static func forUsage(_ usage: UInt32) -> CapLegend {
        if usage == spaceUsage { return .blank }
        if let word = printedWords[usage] { return .word(word) }
        if let shifted = shiftedGlyphs[usage], let base = HIDKeycodes.keyboard[usage] {
            return .pair(shifted: shifted, base: base)
        }
        guard let label = HIDKeycodes.keyboard[usage] else { return .blank }
        return label.count == 1 ? .single(label) : .word(label)
    }

    /// For keymap text that is not a HID usage, like `FN`, `BT1` or a raw
    /// parameter.
    static func forText(_ text: String) -> CapLegend {
        if text.isEmpty { return .blank }
        return text.count == 1 ? .single(text) : .word(text)
    }

    var plain: String {
        switch self {
        case .blank: return ""
        case .single(let s): return s
        case .pair(let shifted, let base): return "\(shifted) \(base)"
        case .word(let w): return w
        }
    }
}
