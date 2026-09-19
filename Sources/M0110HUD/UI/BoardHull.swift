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

    /// Case height at the front edge, 20 mm.
    static let defaultFrontHeight: CGFloat = 105
    /// Case height at the back edge, 45 mm.
    static let defaultBackHeight: CGFloat = 236

    /// Rows of keys occupy 5 units of depth on every variant.
    private static let keyFieldDepth: CGFloat = 500

    static func make(unitsWide: Int32) -> BoardHull {
        BoardHull(
            footprint: CGSize(width: CGFloat(unitsWide) + BoardCase.Bezel.m0110.side * 2,
                              height: keyFieldDepth + BoardCase.Bezel.m0110.top
                                                    + BoardCase.Bezel.m0110.bottom),
            frontHeight: defaultFrontHeight,
            backHeight: defaultBackHeight)
    }

    /// The US ANSI M0110.
    static var m0110: BoardHull { make(unitsWide: M0110Layout.unitsWide) }

    /// Rake of the top surface, degrees, rising toward the back.
    var rakeDegrees: CGFloat {
        atan2(backHeight - frontHeight, footprint.height) * 180 / .pi
    }

    /// A single height for renderers that cannot express a wedge. At HUD size
    /// the rake buys less than the simplicity costs.
    var meanHeight: CGFloat { (frontHeight + backHeight) / 2 }
}
