import SwiftUI

/// One keycap, drawn as vector art from the board photograph rather than as a
/// rounded rectangle with a label in it.
///
/// The caps modelled here are **XDA Oblique**, an AEK-style set in Signature
/// Plastics' XDA profile, in Pantone Cool Gray 2 U. The profile drives the
/// shape in ways that are easy to get wrong by assuming a keycap is a keycap:
///
///  1. **XDA is uniform rather than sculpted.** Every row is the same height
///     and the same shape. Nothing here varies by row, and nothing should:
///     tilting the top faces toward the typist is right for a sculpted set
///     like the board's original Alps caps and wrong for this one.
///  2. **The top is wide and only gently dished.** XDA's defining feature is a
///     large, nearly flat landing area, so the walls are thin and the top face
///     takes up most of the footprint. A deep taper would draw a Cherry cap.
///
/// Every legend is set into the cap's top-left corner, letters included, so
/// they line up with the number row's shifted pairs rather than floating in the
/// middle of their own caps.
///
/// The rest is lighting. The source is at the **lower left**, so:
///
///   * the top face runs light at its left edge, falling back to the cap's own
///     colour at the right
///   * the visible wall is the *lower* one, lit along its face
///   * shadows fall up and to the right, onto the plate
///
/// Get the light direction wrong and every bevel in the drawing inverts at
/// once, leaving the caps reading as pressed rather than proud.
struct Keycap: View {
    let legend: CapLegend
    let isSelected: Bool
    let isEditable: Bool
    /// The spacebar is moulded a shade darker than the rest.
    var isSpacebar = false
    /// Size of the bite out of this cap's top-left corner, in unit-hundredths.
    /// Only the ISO Return has one.
    var cutout: CGSize?
    /// Points per unit-hundredth, so the walls keep their weight at any size.
    let scale: CGFloat

    // MARK: - Walls
    //
    // Thicknesses in unit-hundredths, scaled at use. They are unequal by
    // design: looking down at a cap from slightly in front, the far wall hides
    // behind the top face, the side walls show as slivers, and the near wall,
    // the front skirt, is the only one with real depth.

    /// The far wall, foreshortened almost to nothing.
    private static let topWallUnits: CGFloat = 3
    /// The near wall.
    private static let bottomWallUnits: CGFloat = 13

    /// Height over width of a 1u cap's top face. The face is not square: it is
    /// about a fifth taller than it is wide.
    private static let faceAspect: CGFloat = 1.2

    /// Derived rather than dialled in. The top and bottom walls are fixed by
    /// the sculpt, so they decide the face's height; the side walls are then
    /// whatever makes its width come out at `faceAspect`. Setting all three by
    /// eye is what left the face slightly *wider* than tall, which is the wrong
    /// way round for these caps.
    private static let sideWallUnits: CGFloat = {
        let cell: CGFloat = 100 - BoardCase.keyGap
        let faceHeight = cell - topWallUnits - bottomWallUnits
        return (cell - faceHeight / faceAspect) / 2
    }()

    private var sideWall: CGFloat { max(0.5, Self.sideWallUnits * scale) }
    private var topWall: CGFloat { max(0.5, Self.topWallUnits * scale) }
    private var bottomWall: CGFloat { max(1, Self.bottomWallUnits * scale) }

    private var outerRadius: CGFloat { max(1.5, 9 * scale) }
    private var faceRadius: CGFloat { max(1, 7 * scale) }
    private var hairline: CGFloat { max(0.5, 0.9 * scale) }

    // MARK: - Shape
    //
    // A cap is normally a rounded rectangle and stays one, since
    // `RoundedRectangle` is insettable and its border can be stroked inside the
    // fill. The ISO Return is an L, and takes the polygon path instead.

    private var isL: Bool { cutout != nil }

    /// The bite, in points.
    private var cut: CGSize {
        guard let cutout else { return .zero }
        return CGSize(width: cutout.width * scale, height: cutout.height * scale)
    }

    private var outerShape: AnyShape {
        guard isL else {
            return AnyShape(RoundedRectangle(cornerRadius: outerRadius, style: .continuous))
        }
        let cut = self.cut
        return AnyShape(RoundedPolygon(radius: outerRadius) { r in
            [CGPoint(x: cut.width, y: 0),
             CGPoint(x: r.maxX, y: 0),
             CGPoint(x: r.maxX, y: r.maxY),
             CGPoint(x: 0, y: r.maxY),
             CGPoint(x: 0, y: cut.height),
             CGPoint(x: cut.width, y: cut.height)]
        })
    }

    /// The top face, inset from the moulding. Each edge moves by the wall that
    /// faces its direction, so the L's two extra edges, the left one above the
    /// bite and the top one beside it, are treated exactly like the outer left
    /// and top edges they are parallel to.
    private var faceShape: AnyShape {
        guard isL else {
            return AnyShape(RoundedRectangle(cornerRadius: faceRadius, style: .continuous))
        }
        let cut = self.cut
        let side = sideWall, top = topWall, bottom = bottomWall
        return AnyShape(RoundedPolygon(radius: faceRadius) { r in
            [CGPoint(x: cut.width + side, y: top),
             CGPoint(x: r.maxX - side, y: top),
             CGPoint(x: r.maxX - side, y: r.maxY - bottom),
             CGPoint(x: side, y: r.maxY - bottom),
             CGPoint(x: side, y: cut.height + top),
             CGPoint(x: cut.width + side, y: cut.height + top)]
        })
    }

    // MARK: - Plastic

    private var topColour: Color {
        if isSelected { return Theme.selectedCapTop }
        return isSpacebar ? Theme.spacebarTop : Theme.capTop
    }
    private var skirtColour: Color {
        if isSelected { return Theme.selectedCapSkirt }
        return isSpacebar ? Theme.spacebarSkirt : Theme.capSkirt
    }

    /// The moulding wall. The near wall faces the light, so it is brightest
    /// along the bottom, the opposite of a top-lit drawing.
    private var skirt: LinearGradient {
        LinearGradient(stops: [.init(color: skirtColour.opacity(0.80), location: 0.0),
                               .init(color: skirtColour, location: 0.45),
                               .init(color: skirtColour.opacity(0.86), location: 1.0)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// The top face: a flat fill of the cap's own colour, with all of its
    /// modelling in the sheen laid over it.
    private var face: Color { topColour }

    /// Light running left to right across the dish: the left edge catches it
    /// and the right edge falls back to the cap's plain colour.
    ///
    /// Drawn as white over the fill rather than as a gradient between two
    /// named colours, so the spacebar and the selected cap, which have their
    /// own base colours, get the same treatment without a second constant each
    /// to keep in step.
    private var sheen: LinearGradient {
        LinearGradient(stops: [.init(color: .white.opacity(0.22), location: 0.0),
                               .init(color: .clear, location: 1.0)],
                       startPoint: .leading, endPoint: .trailing)
    }

    /// A warm line. Black outlines are the giveaway that a drawing is a
    /// diagram.
    private var edgeInk: Color {
        (isSelected ? Theme.selectedCapInk : Theme.capInk).opacity(0.22)
    }

    private var ink: Color { isSelected ? Theme.selectedCapInk : Theme.capInk }

    var body: some View {
        ZStack {
            outerShape
                .fill(skirt)
                .overlay(outerShape.stroke(edgeInk, lineWidth: hairline))
                // Up and to the right: away from a light at the lower left.
                .shadow(color: .black.opacity(0.34),
                        radius: max(0.5, 2.2 * scale),
                        x: max(0.2, 1.0 * scale),
                        y: -max(0.2, 0.8 * scale))

            if isL {
                // The face polygon is already inset, so it is laid over the
                // whole frame rather than padded into it.
                faceShape
                    .fill(face)
                    .overlay(faceShape.fill(sheen))
                    .overlay {
                        // On the real cap the legend sits at the top-left of
                        // the wide lower part. Padding the top past the bite
                        // keeps it out of the narrow upper arm, where it would
                        // otherwise land, because the legend views fill
                        // whatever they are given and align themselves inside
                        // it.
                        legendView
                            .padding(.leading, sideWall + max(1, 6 * scale))
                            .padding(.top, cut.height + topWall + max(1, 6 * scale))
                            .padding(.trailing, sideWall)
                            .padding(.bottom, bottomWall)
                    }
            } else {
                faceShape
                    .fill(face)
                    .overlay(faceShape.fill(sheen))
                    .overlay(legendView.padding(max(1, 6 * scale)))
                    .padding(.horizontal, sideWall)
                    .padding(.top, topWall)
                    .padding(.bottom, bottomWall)
            }
        }
        .opacity(isEditable || isSelected ? 1 : 0.62)
        // The bite is transparent, and the key it exposes has to stay clickable.
        .contentShape(outerShape)
    }

    // MARK: - Legends

    /// Sizes are in unit-hundredths so legends scale with the board, and are set
    /// small: on the real caps the lettering occupies far less of the face than
    /// a screen keyboard's usually does.
    private var letterFont: Font { Theme.capLegend(max(5, 26 * scale)) }
    private var pairFont: Font { Theme.capLegend(max(4, 25 * scale)) }
    private var wordFont: Font { Theme.capLegend(max(3.5, 17 * scale)) }

    @ViewBuilder private var legendView: some View {
        switch legend {
        case .blank:
            EmptyView()

        case .single(let glyph):
            Text(glyph)
                .font(letterFont)
                .foregroundStyle(ink)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case .pair(let shifted, let base):
            VStack(alignment: .leading, spacing: max(0, 1 * scale)) {
                Text(shifted)
                Text(base)
            }
            .font(pairFont)
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case .word(let word):
            Text(word)
                .font(wordFont)
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
