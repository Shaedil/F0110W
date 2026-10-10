import SwiftUI

/// One keycap, drawn as vector art.
///
/// Modeled on XDA Oblique caps (Signature Plastics XDA profile, Pantone Cool Gray 2 U).
/// XDA is uniform, so nothing changes by row, and the top is wide and nearly flat,
/// so the walls are thin. Every legend sits in the top-left corner.
///
/// The light comes from the lower left, so the top face is lighter on the left
/// and shadows fall up and to the right.
struct Keycap: View {
    let legend: CapLegend
    let isSelected: Bool
    let isEditable: Bool
    /// The spacebar is moulded a shade darker than the rest.
    var isSpacebar = false
    /// Size of the notch cut from this cap's top-left corner, in hundredths of a
    /// key unit. Only the ISO Return has one.
    var cutout: CGSize?
    /// Points per hundredth of a key unit.
    let scale: CGFloat

    // MARK: - Walls
    // Thicknesses in hundredths of a key unit. Seen from slightly in front, only
    // the near wall shows much depth.

    /// The far wall.
    private static let topWallUnits: CGFloat = 3
    /// The near wall.
    private static let bottomWallUnits: CGFloat = 13

    /// Height over width of a 1u cap's top face.
    private static let faceAspect: CGFloat = 1.2

    /// Computed so the face comes out at `faceAspect`, since the top and bottom
    /// walls fix its height.
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
    // Most caps use `RoundedRectangle`, which can stroke its border inside the
    // fill. The ISO Return is an L and uses a polygon.

    private var isL: Bool { cutout != nil }

    /// The notch, in points.
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

    /// The top face, inset on each side by that side's wall, including the L's
    /// inner edges.
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

    /// The wall is brightest at the bottom because the light is at the lower left.
    private var skirt: LinearGradient {
        LinearGradient(stops: [.init(color: skirtColour.opacity(0.80), location: 0.0),
                               .init(color: skirtColour, location: 0.45),
                               .init(color: skirtColour.opacity(0.86), location: 1.0)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var face: Color { topColour }

    /// White fading out left to right. Drawn over the fill so caps with other
    /// base colors (spacebar, selected) get the same effect.
    private var sheen: LinearGradient {
        LinearGradient(stops: [.init(color: .white.opacity(0.22), location: 0.0),
                               .init(color: .clear, location: 1.0)],
                       startPoint: .leading, endPoint: .trailing)
    }

    /// Warm outline, since black outlines make the art look like a diagram.
    private var edgeInk: Color {
        (isSelected ? Theme.selectedCapInk : Theme.capInk).opacity(0.22)
    }

    private var ink: Color { isSelected ? Theme.selectedCapInk : Theme.capInk }

    var body: some View {
        ZStack {
            outerShape
                .fill(skirt)
                .overlay(outerShape.stroke(edgeInk, lineWidth: hairline))
                // Shadow falls up and right, away from the light.
                .shadow(color: .black.opacity(0.34),
                        radius: max(0.5, 2.2 * scale),
                        x: max(0.2, 1.0 * scale),
                        y: -max(0.2, 0.8 * scale))

            if isL {
                // The L face path is already inset, so it gets no padding.
                faceShape
                    .fill(face)
                    .overlay(faceShape.fill(sheen))
                    .overlay {
                        // Pad past the notch so the legend sits in the wide
                        // lower part, like on the real cap.
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
        // The notch is transparent, and the key under it has to stay clickable.
        .contentShape(outerShape)
    }

    // MARK: - Legends

    /// Sizes are in hundredths of a key unit so legends scale with the board.
    /// They are small to match the real caps.
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
