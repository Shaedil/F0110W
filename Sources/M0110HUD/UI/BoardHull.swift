import CoreGraphics
import Foundation

/// The M0110 case as a solid: its footprint, its two heights, and the rake
/// between them.
///
/// The footprint is the drawn board's own, `M0110Layout`'s key field plus
/// `BoardCase`'s margins, so the 3D board in the HUD and the 2D board in the
/// Keys pane are the same size and shape by construction rather than by two
/// numbers being kept in agreement.
///
/// Only the heights are new information, and they come from the physical board
/// converted at 100 units = 19.05 mm, so they can be checked against a ruler
/// instead of taken on trust. The rake then falls out of them rather than being
/// dialled in by eye: 11.9° over this depth, against the real board's ~12°.
struct BoardHull {
    /// Footprint in hundredths of a key unit, `y` growing toward the back.
    let footprint: CGSize
    /// Case height at the front edge, same unit.
    let frontHeight: CGFloat
    /// Case height at the back edge.
    let backHeight: CGFloat

    /// Case height at the front edge, 28.6 mm.
    ///
    /// Raised from the 105 (20 mm) recorded here before. At that value the case
    /// rendered as a thin slab and the taper was far too hard: back-to-front
    /// came out 2.25:1, where measuring the two edges across a side-on
    /// photograph of the real board gives about 1.65:1. The rake is what
    /// matters and it is preserved exactly -- both heights moved by the same
    /// 45 units, so `backHeight - frontHeight` is unchanged and the top surface
    /// still falls at 12.3 degrees.
    ///
    /// These two are the least certain numbers in this file. If the real case
    /// is put against a ruler, replace them and delete this note.
    static let defaultFrontHeight: CGFloat = 150
    /// Case height at the back edge, 53.5 mm.
    static let defaultBackHeight: CGFloat = 281

    /// Width of the flat rim running round the underside, 11.4 mm.
    ///
    /// The underside is not one plane. A rim of constant height goes all the
    /// way round, level front to back, and the rake belongs entirely to the
    /// platform inside it — which is why the case does not read as a plain
    /// wedge from below. The feet, the spec label and the vents all sit on the
    /// platform.
    static let defaultRimWidth: CGFloat = 60
    /// How far the platform stands proud of the rim.
    ///
    /// 5 mm, which is deeper than the real step. This is the one number here
    /// that is drawn rather than measured: at glyph size the board is about
    /// 90pt across, so the true 2.7 mm step renders under a pixel and the
    /// underside goes back to reading as one flat slab. Everything else in
    /// `BoardHull` is off the real case and should stay that way.
    static let defaultRimDrop: CGFloat = 26

    let rimWidth: CGFloat
    /// Depth of the step between the rim and the platform.
    let rimDrop: CGFloat

    /// Rows of keys occupy 5 units of depth on every variant.
    private static let keyFieldDepth: CGFloat = 500

    static func make(unitsWide: Int32) -> BoardHull {
        BoardHull(
            footprint: CGSize(width: CGFloat(unitsWide) + BoardCase.Bezel.m0110.side * 2,
                              height: keyFieldDepth + BoardCase.Bezel.m0110.top
                                                    + BoardCase.Bezel.m0110.bottom),
            frontHeight: defaultFrontHeight,
            backHeight: defaultBackHeight,
            rimWidth: defaultRimWidth,
            rimDrop: defaultRimDrop)
    }

    /// The US ANSI M0110.
    static var m0110: BoardHull { make(unitsWide: M0110Layout.unitsWide) }

    /// How deep the keys sit below the bezel around them.
    ///
    /// The caps are not painted on a flat lid: they stand in a well with walls
    /// you can see down into, which is most of why the real case reads as a
    /// solid object rather than a printed slab.
    static let defaultWellDepth: CGFloat = 34
    var wellDepth: CGFloat { Self.defaultWellDepth }

    /// Height of the moulding seam above the underside rim, as a fraction of
    /// the wall it sits on.
    ///
    /// The upper and lower shells meet here, and they do not meet flush: the
    /// upper shell overhangs and the lower one is set back behind it, so the
    /// case has a lip near the top and then steps in. Seen end-on it reads as a
    /// cliff edge, and it is the most conspicuous thing on the case after the
    /// rake itself.
    var seamFraction: CGFloat { 0.62 }
    /// How far the lower shell is set back from the upper one, 4.8 mm.
    var lipInset: CGFloat { 25 }

    /// Where the sloping key deck is set in from each case edge, taken from the
    /// same bezel `BoardArtView` draws, so the solid and the flat art cannot
    /// disagree about where the border ends and the keys begin.
    var deckInsetSide: CGFloat { BoardCase.Bezel.m0110.side }
    var deckInsetFront: CGFloat { BoardCase.Bezel.m0110.bottom }
    var deckInsetBack: CGFloat { BoardCase.Bezel.m0110.top }

    /// Rake of the top surface, degrees, rising toward the back.
    var rakeDegrees: CGFloat {
        atan2(backHeight - frontHeight, footprint.height) * 180 / .pi
    }
}
