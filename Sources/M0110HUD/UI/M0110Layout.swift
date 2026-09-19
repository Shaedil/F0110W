import CoreGraphics
import Foundation

/// One key as drawn, paired with the firmware keymap position it edits.
///
/// `labeled` is false where a key is drawn as more than one rectangle and only
/// one of them should carry the legend. Two physically distinct keys that share
/// a scancode (the Shifts, the Commands) are both labelled, because they really
/// are two keys.
///
/// `cutout` is how the ISO Return is described: a two-row bounding box with its
/// top-left corner missing, drawn as a single L-shaped cap. It used to be two
/// separate rectangles, which drew two keycaps with a moulding line between
/// them where the real key has none.
struct DisplayKey {
    let position: Int
    let attrs: KeyPhysicalAttrs
    var labeled = true
    /// Size of the rectangle missing from the box's top-left corner, in
    /// unit-hundredths. Nil for an ordinary rectangular key.
    var cutout: CGSize?
}

/// Display geometry for the US ANSI M0110.
///
/// The shield's `m0110a_layout` is a superset covering every variant, so the
/// firmware reports 79 positions with ISO proportions: a narrow 1.25u Return
/// and an extra non-US backslash, neither of which a US board has. This table
/// re-lays the same firmware positions at true ANSI widths, departing from what
/// the firmware reports in these places:
///
///   * position 53 (non-US backslash) is dropped, since the key does not exist
///   * position 47 (Return) widens from 1.25u to 2.25u
///   * position 72 (backslash) moves from the bottom row up to the end of the
///     tab row, where an ANSI board puts it
///
/// Positions are the dtsi's declaration order: row 0 is 0-13 then 14-17 numpad,
/// row 1 is 18 (Tab), 19-30, 31-34 numpad, row 2 is 35 (Caps), 36-46, 47
/// (Return), 48-51 numpad, row 3 is 52 (LShift), 53 (ISO), 54-63, 64 (RShift),
/// 65 (Up), 66-68 numpad, row 4 is 69-75 then 76-78 numpad.
enum M0110Layout {
    /// Board width in hundredths of a key unit.
    static let unitsWide: Int32 = 1500

    /// The empty space at the left of the bottom row, which carries the Apple
    /// logo. **Exactly one key unit**, which is what the real board leaves and
    /// what makes the logo's cell square.
    ///
    /// That squareness matters. The logo's left and bottom edges are
    /// alignments, flush with the column of keys above and with the bottom of
    /// the spacebar, and its top and right edges are gaps to neighbouring keys.
    /// A *square* logo with two edges anchored can only clear both neighbours
    /// by the same amount if the cell it sits in is itself square; in a
    /// 121-wide cell it was always 21 units further from one than the other, at
    /// any size.
    static let bottomRowLeftInset: Int32 = 100

    /// The bottom row is centred: the same inset at each end, which is also the
    /// Apple logo's cell.
    ///
    /// The spacebar takes up whatever is left over, rather than being a
    /// measured width of its own. With a square logo cell and a symmetric row
    /// both required and every other key in the row fixed, the spacebar is the
    /// only thing that can satisfy both. Give it a measured width instead and
    /// the row lands 42 units off-centre.
    private static let bottomRowFixedWidths: Int32 = 98 + 149 + 140 + 95
    static let spacebarWidth: Int32 = unitsWide - bottomRowLeftInset * 2 - bottomRowFixedWidths
    static let spacebarX: Int32 = bottomRowLeftInset + 98 + 149
    /// Where the row ends, working forward through Enter and Option.
    static let bottomRowRightEnd: Int32 = spacebarX + spacebarWidth + 140 + 95

    /// The bezel cell carrying the Apple logo, in key-field coordinates.
    static let appleLogoCell = CGRect(x: 0, y: 400,
                                      width: CGFloat(bottomRowLeftInset), height: 100)

    /// The two parts of the plate that are really bezel.
    ///
    /// The M0110's bottom row is inset at both ends: the empty unit at the left
    /// carries the Apple logo, and the board photograph shows case, not plate,
    /// in the gap at the right. Each one runs out past the plate's edge so it
    /// opens into the surrounding bezel rather than floating in the black as a
    /// bright island, and each is held back half a gap from the neighbouring
    /// keycap so the black beside it measures the same as everywhere else.
    ///
    /// The M0110A's bottom row runs the full width and has neither.
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

    /// The spacebar's firmware position, the same on both variants. Used for
    /// the cap's colour, which is a property of the moulding rather than of the
    /// binding: a spacebar rebound to something else is still a spacebar.
    static let spacebarPosition = 71

    /// A key the board has but the matrix transform does not expose. The photo
    /// shows Enter to the right of the spacebar; the keymap's bottom row holds
    /// only LCTRL, LGUI, SPACE and `lt FN BSLH`, and that backslash belongs to
    /// the tab row, so no position is left for Enter.
    static let unmapped = -1


    /// Board width for the M0110A: 15u main block, then the numpad.
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

        // Row 3: no ISO key. Both Shift keys share position 52, so the right
        // one is a second keycap onto the same position.
        add(52, x: 0, y: 300, w: 225)
        for (n, position) in (54...63).enumerated() {
            add(position, x: 225 + Int32(n) * 100, y: 300, w: 100)
        }
        add(52, x: 1225, y: 300, w: 275)

        // Row 4: Option, Command, Space, Enter, Option, inset on both sides
        // with the embossed Apple logo occupying the space at the left.
        //
        // Widths are measured off the board photograph, but the *positions* are
        // packed tight against the spacebar rather than measured. Photograph
        // measurements carried 9-14 units of their own spacing between these
        // keys, which lands on top of the `keyGap` every cell already leaves,
        // so the bottom row sat visibly looser than the four rows above it.
        // Every other row is contiguous; this one now is too.
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

    /// Display geometry for the M0110A.
    ///
    /// The firmware's own `keys` list is functional but not shaped like the
    /// board: its rows end raggedly between 13u and 14.25u, and Return is a
    /// squat 1.25u single-height key. A real M0110A has a flush 15u main block
    /// and the tall ISO Return.
    ///
    /// Return is drawn as two keycaps, a 2.25u lower half and a 1.5u upper
    /// half, both onto position 47, because that L is one key and a single
    /// rectangle cannot describe it. Clicking either half selects the same
    /// binding.
    ///
    /// The numpad keeps the firmware's arrangement, shifted right to leave the
    /// 1u channel the real board has between the two halves.
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

        // Row 1: 1.5u tab, then the brackets. The ISO Return closes the row
        // and carries on into the one below: a 2.25u x 2-row box with a
        // 0.75u x 1-row bite out of its top-left, which is the "big ass enter".
        // It is added here, after the key it sits beside, so it draws on top:
        // its bite is transparent and the key under it has to show through.
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

        // Row 3: wide shifts and Up. The photograph shows no ISO key, so
        // position 53 is dropped here as well as on the M0110.
        add(52, x: 0, y: 300, w: 225)
        for (n, position) in (54...63).enumerated() {
            add(position, x: 225 + Int32(n) * 100, y: 300, w: 100)
        }
        add(64, x: 1225, y: 300, w: 175)
        add(65, x: 1400, y: 300, w: 100)

        // Row 4: Option 1.5u, Command 2u, a 7.5u spacebar, then backslash and
        // the arrows. Command is the wider of the two modifiers on this board,
        // which is the other way round from most keyboards and easy to get
        // backwards.
        add(69, x: 0, y: 400, w: 150)
        add(70, x: 150, y: 400, w: 200)
        add(71, x: 350, y: 400, w: 750)
        add(72, x: 1100, y: 400, w: 100)
        add(73, x: 1200, y: 400, w: 100)
        add(74, x: 1300, y: 400, w: 100)
        add(75, x: 1400, y: 400, w: 100)

        // Numpad: columns are wider than the main block's keys in the
        // photograph, so the pitch here is 110 rather than 100.
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
