import CoreGraphics
import Foundation

/// The M0110 case as a solid: its footprint, front and back heights, and the
/// slope between them.
///
/// The footprint is the same as the 2D board in the Keys pane. Heights come
/// from the real board, converted at 100 units = 19.05 mm.
struct BoardHull {
    /// Footprint in hundredths of a key unit, `y` growing toward the back.
    let footprint: CGSize
    let frontHeight: CGFloat
    let backHeight: CGFloat

    /// Case height at the front edge, 28.6 mm. This and the back height were
    /// estimated from a side photo (about 1.65:1 back to front), so replace both
    /// if the real case gets measured.
    static let defaultFrontHeight: CGFloat = 150
    /// Case height at the back edge, 53.5 mm.
    static let defaultBackHeight: CGFloat = 281

    /// Width of the flat rim around the underside, 11.4 mm. The rim is level and
    /// only the platform inside it slopes. The feet, label and vents sit on the platform.
    static let defaultRimWidth: CGFloat = 60
    /// How far the platform sticks out past the rim, 5 mm. The real step is 2.7 mm,
    /// but that is under a pixel at HUD size. This is the only number here that
    /// is not measured from the real case.
    static let defaultRimDrop: CGFloat = 26

    let rimWidth: CGFloat
    let rimDrop: CGFloat

    /// The key rows are 5 units deep on every variant.
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

    /// How deep the key well sits below the bezel around it.
    static let defaultWellDepth: CGFloat = 34
    var wellDepth: CGFloat { Self.defaultWellDepth }

    /// Height of the seam between the upper and lower shells, as a fraction of
    /// the wall. The upper shell overhangs, so the case steps in below this line.
    var seamFraction: CGFloat { 0.62 }
    /// How far the lower shell is set back from the upper one, 4.8 mm.
    var lipInset: CGFloat { 25 }

    /// How far the sloped key deck is inset from each case edge. Uses the same
    /// bezel `BoardArtView` draws so the 3D and 2D boards line up.
    var deckInsetSide: CGFloat { BoardCase.Bezel.m0110.side }
    var deckInsetFront: CGFloat { BoardCase.Bezel.m0110.bottom }
    var deckInsetBack: CGFloat { BoardCase.Bezel.m0110.top }

    /// Slope of the top surface in degrees, rising toward the back.
    var rakeDegrees: CGFloat {
        atan2(backHeight - frontHeight, footprint.height) * 180 / .pi
    }
}
