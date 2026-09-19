import Foundation

/// How an M0110 keycap is printed.
///
/// The board prints each kind of cap differently, and using one treatment for
/// everything is most of what makes a drawn keyboard look generic rather than
/// like this keyboard:
///
///   * a **word** (`Tab`, `Caps Lock`, `Shift`, `Option`, `Return`,
///     `Backspace`, `Enter`) set small in the cap's top-left corner
///   * a **pair**, the number row and the punctuation keys, with the shifted
///     glyph above the unshifted one, left-aligned as a column
///   * a **single** glyph, the letters, centred and larger
///
/// The spacebar is blank.
///
/// Pairs and words are derived from the HID usage rather than written out per
/// key, so a cap rebound in the picker reprints itself correctly instead of
/// keeping the legend of whatever used to be bound there.
enum CapLegend {
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

    /// What the board prints in words, which is not always what the app calls
    /// the key elsewhere: the M0110's delete key is printed `Backspace`, and
    /// the command key carries the looped square on its own with no text.
    private static let printedWords: [UInt32: String] = [
        0x28: "Return", 0x29: "Esc", 0x2A: "Backspace", 0x2B: "Tab",
        0x39: "Caps Lock", 0x58: "Enter",
        0xE0: "Control", 0xE1: "Shift", 0xE2: "Option", 0xE3: "\u{2318}",
        0xE4: "Control", 0xE5: "Shift", 0xE6: "Option", 0xE7: "\u{2318}",
    ]

    /// The spacebar.
    private static let spaceUsage: UInt32 = 0x2C

    static func forUsage(_ usage: UInt32) -> CapLegend {
        if usage == spaceUsage { return .blank }
        if let word = printedWords[usage] { return .word(word) }
        if let shifted = shiftedGlyphs[usage], let base = HIDKeycodes.keyboard[usage] {
            return .pair(shifted: shifted, base: base)
        }
        guard let label = HIDKeycodes.keyboard[usage] else { return .blank }
        // One glyph is a letter and gets centred; anything longer is a word.
        return label.count == 1 ? .single(label) : .word(label)
    }

    /// A legend for text the keymap produced that is not a plain HID usage:
    /// `FN`, `BT1`, a raw parameter. Short enough to centre, otherwise a word.
    static func forText(_ text: String) -> CapLegend {
        if text.isEmpty { return .blank }
        return text.count == 1 ? .single(text) : .word(text)
    }

    /// Plain text, for anything that needs the legend as a string, such as a
    /// tooltip or an accessibility label.
    var plain: String {
        switch self {
        case .blank: return ""
        case .single(let s): return s
        case .pair(let shifted, let base): return "\(shifted) \(base)"
        case .word(let w): return w
        }
    }
}
