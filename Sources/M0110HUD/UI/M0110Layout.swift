#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// One key as drawn, with the firmware keymap position it edits. `labeled` is
/// false on the extra pieces of a key drawn as more than one rectangle.
struct DisplayKey {
    let position: Int
    let attrs: KeyPhysicalAttrs
    var labeled = true
    /// Notch cut from the top-left corner (the ISO Return), in hundredths of a
    /// key unit. Nil for a plain rectangle.
    var cutout: CGSize?
}

/// Display geometry for the US ANSI M0110.
///
/// The firmware's `m0110a_layout` covers every model with ISO proportions. This
/// table draws the same positions at ANSI widths: 53 (non-US backslash) is
/// dropped, 47 (Return) widens from 1.25u to 2.25u, and 72 (backslash) moves up
/// to the end of the tab row.
///
/// Positions follow the dtsi order: row 0 is 0-13 then 14-17 numpad,
/// row 1 is 18 (Tab), 19-30, 31-34 numpad, row 2 is 35 (Caps), 36-46, 47
/// (Return), 48-51 numpad, row 3 is 52 (LShift), 53 (ISO), 54-63, 64 (RShift),
/// 65 (Up), 66-68 numpad, row 4 is 69-75 then 76-78 numpad.
enum M0110Layout {
    /// Board width in hundredths of a key unit.
    static let unitsWide: Int32 = 1500

    /// Empty space at the left of the bottom row, where the Apple logo sits.
    /// It is exactly 1u, as on the real board, so the logo cell is square and
    /// the logo clears its top and right neighbors by the same amount.
    static let bottomRowLeftInset: Int32 = 100

    /// The bottom row has the same inset at both ends, so the spacebar takes
    /// whatever width is left. A measured spacebar width puts the row 42 units
    /// off center.
    private static let bottomRowFixedWidths: Int32 = 98 + 149 + 140 + 95
    static let spacebarWidth: Int32 = unitsWide - bottomRowLeftInset * 2 - bottomRowFixedWidths
    static let spacebarX: Int32 = bottomRowLeftInset + 98 + 149
    /// Right end of the bottom row, after Enter and Option.
    static let bottomRowRightEnd: Int32 = spacebarX + spacebarWidth + 140 + 95

    /// The bezel cell carrying the Apple logo, in key-field coordinates.
    static let appleLogoCell = CGRect(x: 0, y: 400,
                                      width: CGFloat(bottomRowLeftInset), height: 100)

    /// Parts of the plate that are really bezel: the empty cells at both ends
    /// of the M0110's bottom row. Each runs past the plate edge to join the
    /// bezel, and stops half a gap short of the next keycap so the black gap
    /// matches the rest of the board.
    static let bezelPatches: [CGRect] = {
        let inset = BoardCase.plateInset
        let half = BoardCase.keyGap / 2
        let firstCap = CGFloat(bottomRowLeftInset)
        let lastCapEnd = CGFloat(bottomRowRightEnd)
        let field = CGFloat(unitsWide)
        return [
            CGRect(x: -inset, y: 400 + half,
                   width: firstCap - half + inset,
                   height: 100 - half + inset),
            CGRect(x: lastCapEnd + half, y: 400 + half,
                   width: field - lastCapEnd - half + inset,
                   height: 100 - half + inset),
        ]
    }()

    /// The spacebar's firmware position on both models. Its cap color follows
    /// the position, so a rebound spacebar keeps it.
    static let spacebarPosition = 71

    /// Marks a key the board has but the matrix transform does not expose: the
    /// Enter right of the spacebar. The keymap's bottom row has no slot for it.
    static let unmapped = -1


    static let m0110aUnitsWideMeasured: Int32 = 1960


    static let ansi: [DisplayKey] = {
        var keys: [DisplayKey] = []
        func add(_ position: Int, x: Int32, y: Int32, w: Int32, h: Int32 = 100) {
            keys.append(DisplayKey(position: position,
                                   attrs: KeyPhysicalAttrs(width: w, height: h, x: x, y: y)))
        }

        // Row 0: number row, 2u backspace.
        for i in 0...12 { add(i, x: Int32(i) * 100, y: 0, w: 100) }
        add(13, x: 1300, y: 0, w: 200)

        // Row 1: 1.5u tab, the brackets, then the backslash.
        add(18, x: 0, y: 100, w: 150)
        for (n, position) in (19...30).enumerated() {
            add(position, x: 150 + Int32(n) * 100, y: 100, w: 100)
        }
        add(72, x: 1350, y: 100, w: 150)

        // Row 2: 1.75u caps, 2.25u ANSI return.
        add(35, x: 0, y: 200, w: 175)
        for (n, position) in (36...46).enumerated() {
            add(position, x: 175 + Int32(n) * 100, y: 200, w: 100)
        }
        add(47, x: 1275, y: 200, w: 225)

        // Row 3: no ISO key. Both Shifts share position 52.
        add(52, x: 0, y: 300, w: 225)
        for (n, position) in (54...63).enumerated() {
            add(position, x: 225 + Int32(n) * 100, y: 300, w: 100)
        }
        add(52, x: 1225, y: 300, w: 275)

        // Row 4: Option, Command, Space, Enter, Option, with the Apple logo in
        // the gap at the left. Widths come from the photo, but the keys are
        // packed against the spacebar. The photo's spacing added to `keyGap`
        // and made this row looser than the others.
        add(69, x: bottomRowLeftInset, y: 400, w: 98)
        add(70, x: bottomRowLeftInset + 98, y: 400, w: 149)
        add(71, x: spacebarX, y: 400, w: spacebarWidth)
        add(M0110Layout.unmapped, x: spacebarX + spacebarWidth, y: 400, w: 140)
        add(64, x: spacebarX + spacebarWidth + 140, y: 400, w: 95)

        return keys
    }()

    /// Every firmware position the ANSI board actually has a key for.
    static let ansiPositions: Set<Int> = Set(ansi.map(\.position))

    /// Board width for the M0110A, main block plus the gap and numpad.
    static let m0110aUnitsWide: Int32 = m0110aUnitsWideMeasured

    /// Display geometry for the M0110A. The firmware's own key list has ragged
    /// rows and a 1.25u Return, but the real board has a flush 15u main block
    /// and a tall ISO Return.
    static let m0110a: [DisplayKey] = {
        var keys: [DisplayKey] = []
        func add(_ position: Int, x: Int32, y: Int32, w: Int32, h: Int32 = 100,
                 labeled: Bool = true, cutout: CGSize? = nil) {
            keys.append(DisplayKey(position: position,
                                   attrs: KeyPhysicalAttrs(width: w, height: h, x: x, y: y),
                                   labeled: labeled,
                                   cutout: cutout))
        }

        // Row 0: number row, 2u backspace.
        for i in 0...12 { add(i, x: Int32(i) * 100, y: 0, w: 100) }
        add(13, x: 1300, y: 0, w: 200)

        // Row 1: 1.5u tab, then the brackets. The ISO Return is a 2.25u x 2-row
        // box with a 0.75u x 1-row notch at the top-left. It is added after its
        // neighbor so it draws on top and the notch shows the key beneath.
        add(18, x: 0, y: 100, w: 150)
        for (n, position) in (19...30).enumerated() {
            add(position, x: 150 + Int32(n) * 100, y: 100, w: 100)
        }
        add(47, x: 1275, y: 100, w: 225, h: 200,
            cutout: CGSize(width: 75, height: 100))

        // Row 2: 1.75u caps, running up to the Return's lower half.
        add(35, x: 0, y: 200, w: 175)
        for (n, position) in (36...46).enumerated() {
            add(position, x: 175 + Int32(n) * 100, y: 200, w: 100)
        }

        // Row 3: wide Shifts and Up. The photo shows no ISO key, so 53 is dropped.
        add(52, x: 0, y: 300, w: 225)
        for (n, position) in (54...63).enumerated() {
            add(position, x: 225 + Int32(n) * 100, y: 300, w: 100)
        }
        add(64, x: 1225, y: 300, w: 175)
        add(65, x: 1400, y: 300, w: 100)

        // Row 4: Option 1.5u, Command 2u, 7.5u spacebar, backslash, arrows.
        // Command is wider than Option on this board, unlike most keyboards.
        add(69, x: 0, y: 400, w: 150)
        add(70, x: 150, y: 400, w: 200)
        add(71, x: 350, y: 400, w: 750)
        add(72, x: 1100, y: 400, w: 100)
        add(73, x: 1200, y: 400, w: 100)
        add(74, x: 1300, y: 400, w: 100)
        add(75, x: 1400, y: 400, w: 100)

        // Numpad keys are wider than main-block keys in the photo, so the pitch is 110.
        let pad: Int32 = 1520
        let col: Int32 = 110
        for (n, position) in (14...17).enumerated() { add(position, x: pad + Int32(n) * col, y: 0, w: col) }
        for (n, position) in (31...34).enumerated() { add(position, x: pad + Int32(n) * col, y: 100, w: col) }
        for (n, position) in (48...51).enumerated() { add(position, x: pad + Int32(n) * col, y: 200, w: col) }
        for (n, position) in (66...68).enumerated() { add(position, x: pad + Int32(n) * col, y: 300, w: col) }
        add(76, x: pad, y: 400, w: col * 2)
        add(77, x: pad + col * 2, y: 400, w: col)
        add(78, x: pad + col * 3, y: 300, w: col, h: 200)

        return keys
    }()
}
