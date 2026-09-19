import SwiftUI

/// The keyboard case: a flat beige bezel around a black plate. On the M0110 the
/// Apple logo sits in a recess in the bottom-left corner, where the bottom row
/// leaves a unit empty.
///
/// Geometry is in the same hundredths-of-a-key-unit space as `DisplayKey`, so
/// the case and the key overlay cannot drift apart.
///
/// ## The bezel differs between the variants
///
/// The compact M0110's flat is thin along the top and bottom and about three
/// times as wide down each side; drawn as an even margin the board comes out
/// too square. The M0110A is a plain even frame. See `Bezel`.
///
/// ## A flat bezel
///
/// The bezel takes no gradient, chamfer or drop shadow. Shading it made the
/// case read as a rendered object floating over the page; the real thing is a
/// large matte surface with no visible falloff across it, and a flat fill
/// leaves the black plate and the keycaps to do the work.
struct BoardCase: View {
    /// Key-field width in unit-hundredths (1500 for the M0110, 1960 for the A).
    let unitsWide: Int32
    /// The plate blocks the keys sit on, in unit-hundredths.
    let wells: [CGRect]
    /// Rectangles bitten out of a plate block, where the bezel shows through.
    /// The M0110's bottom row is inset at both ends, and on the real board those
    /// two gaps are case. Nothing is drawn for them: they are holes in the
    /// plate's outline, so the bezel behind shows.
    var bezelPatches: [CGRect] = []
    /// Where the Apple logo goes, in key-field coordinates. Nil on the M0110A,
    /// whose bottom row runs the full width and leaves no room for it.
    var logoCell: CGRect?
    /// Points per unit-hundredth.
    let scale: CGFloat

    /// Bezel widths, in unit-hundredths. Per variant, because the two boards
    /// are not the same shape.
    struct Bezel {
        let side: CGFloat
        let top: CGFloat
        let bottom: CGFloat

        /// The compact M0110: thin along the top and bottom, two and a half
        /// times as wide down each side.
        static let m0110 = Bezel(side: 125, top: 50, bottom: 50)

        /// The M0110A: an even frame all the way round. The extra width down
        /// the sides belongs to the compact board; the A is wide enough already
        /// that repeating it would leave the case looking stretched.
        static let m0110a = Bezel(side: 50, top: 50, bottom: 50)
    }

    var bezel: Bezel = .m0110
    private static let unitsTall: CGFloat = 500

    static func size(unitsWide: Int32, bezel: Bezel, scale: CGFloat) -> CGSize {
        CGSize(width: (CGFloat(unitsWide) + bezel.side * 2) * scale,
               height: (unitsTall + bezel.top + bezel.bottom) * scale)
    }

    private var box: CGSize { Self.size(unitsWide: unitsWide, bezel: bezel, scale: scale) }
    private var shellRadius: CGFloat { max(3, 22 * scale) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            shell
            ForEach(Array(wells.enumerated()), id: \.offset) { _, rect in
                plateView(rect)
            }
            if let logoCell { appleLogo(in: logoCell) }
        }
        .frame(width: box.width, height: box.height, alignment: .topLeading)
    }

    // MARK: - Shell

    private var shellShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: shellRadius, style: .continuous)
    }

    /// One flat colour. See the note above.
    private var shell: some View {
        shellShape
            .fill(Theme.caseFlat)
            .frame(width: box.width, height: box.height)
    }

    // MARK: - Plate

    /// Black showing between two neighbouring keycaps, in unit-hundredths.
    ///
    /// One constant drives every gap in the drawing. It used to be two: a
    /// point-valued gap between caps and a unit-valued plate inset. Those are
    /// different units, so they could not stay in step at any scale, and the
    /// border around the block came out about four times the gaps inside it.
    static let keyGap: CGFloat = 7

    /// How far the plate extends past the key field on every side.
    ///
    /// Exactly half a gap. Each cap already holds back half a gap inside its
    /// own cell, so half a gap of plate beyond the field makes the outer border
    /// measure the same as the gap between two caps.
    static var plateInset: CGFloat { keyGap / 2 }

    /// Corner radius of the black, applied to every corner of its outline.
    static let plateRadius: CGFloat = 13

    /// The black plate the keys stand on, which is what shows in the gaps
    /// between caps.
    ///
    /// Drawn as **one rounded polygon** rather than a rounded rectangle with
    /// beige patches laid over its corners, because:
    ///
    ///  1. A notch in an edge creates three corners, two convex and one
    ///     concave, and a rectangular patch can only round the concave one.
    ///     The other two are T-junctions between the patch's edge and the
    ///     plate's, and no corner radius on a *rectangle* can round them.
    ///  2. Two shapes sharing a path are each antialiased on their own, and
    ///     their partial coverages do not add back to one. Along a straight
    ///     edge that is an invisible hairline; along a corner arc it reads as a
    ///     dark crescent.
    ///
    /// As one path, every corner is just a corner, and
    /// `addArc(tangent1End:tangent2End:radius:)` rounds convex and concave
    /// alike.
    private func plateView(_ well: CGRect) -> some View {
        let plate = well.insetBy(dx: -Self.plateInset, dy: -Self.plateInset)
        let points = outline(for: plate).map {
            CGPoint(x: ($0.x + bezel.side) * scale,
                    y: ($0.y + bezel.top) * scale)
        }
        return RoundedPolygon(radius: max(1.5, Self.plateRadius * scale),
                              points: points)
            .fill(Theme.plate)
    }

    /// The outline of one plate block, clockwise, in field coordinates.
    ///
    /// The only notches this board has are at the two bottom corners, where the
    /// bottom row is inset at each end, so rather than general polygon
    /// subtraction this handles exactly that case: a rectangle with up to one
    /// bite out of each bottom corner.
    private func outline(for plate: CGRect) -> [CGPoint] {
        let e: CGFloat = 0.5
        let bottom = bezelPatches.filter {
            $0.intersects(plate) && abs($0.maxY - plate.maxY) < e
        }
        let left = bottom.first { abs($0.minX - plate.minX) < e }
        let right = bottom.first { abs($0.maxX - plate.maxX) < e }

        guard let notchY = (left ?? right)?.minY else {
            return [CGPoint(x: plate.minX, y: plate.minY),
                    CGPoint(x: plate.maxX, y: plate.minY),
                    CGPoint(x: plate.maxX, y: plate.maxY),
                    CGPoint(x: plate.minX, y: plate.maxY)]
        }

        var points = [CGPoint(x: plate.minX, y: plate.minY),
                      CGPoint(x: plate.maxX, y: plate.minY)]
        if let right {
            points.append(CGPoint(x: plate.maxX, y: notchY))
            points.append(CGPoint(x: right.minX, y: notchY))
            points.append(CGPoint(x: right.minX, y: plate.maxY))
        } else {
            points.append(CGPoint(x: plate.maxX, y: plate.maxY))
        }
        if let left {
            points.append(CGPoint(x: left.maxX, y: plate.maxY))
            points.append(CGPoint(x: left.maxX, y: notchY))
            points.append(CGPoint(x: plate.minX, y: notchY))
        } else {
            points.append(CGPoint(x: plate.minX, y: plate.maxY))
        }
        return points
    }

    // MARK: - Emboss

    /// The Apple logo in a rounded-square recess cut into the bezel.
    ///
    /// The recess is what gives the logo its contrast. Moulded flush onto the
    /// case, in the case's own beige, the logo is a shape with nothing behind
    /// it and all but disappears. Cutting a pocket puts a shaded floor behind
    /// the relief, and the two edges of the pocket read as depth in the
    /// surrounding plastic.
    ///
    /// Lighting is the inverse of a raised object's. With the light at the
    /// lower left, a proud edge is bright on its lower-left face; the *inside*
    /// of a pocket is the other way round, with its lower-left wall shading the
    /// floor and its upper-right wall catching the light. Getting that
    /// backwards makes a recess look like a sticker.
    ///
    /// The glyph, as a fraction of the pocket.
    private static let glyphFill: CGFloat = 0.72

    /// A square, with two of its edges alignments and two of them gaps.
    ///
    /// Left edge flush with the column of keys above it, bottom edge flush with
    /// the bottom of the spacebar beside it. The top and right edges are the
    /// free ones, and each clears its neighbouring key by `logoKeyGap`, which
    /// is wider than the gap between two keycaps because the logo is case
    /// rather than a key and should not read as one.
    ///
    /// This closes only because `M0110Layout.appleLogoCell` is square; see the
    /// note on `bottomRowLeftInset`.
    private static let logoKeyGap: CGFloat = keyGap * 2

    private func appleLogo(in cell: CGRect) -> some View {
        let half = Self.keyGap / 2
        // Square, anchored to its two alignment edges, sized so its two gap
        // edges each clear their neighbouring key by `logoKeyGap`.
        let sideUnits = min(cell.width, cell.height) - Self.logoKeyGap
        let box = CGRect(x: cell.minX + half,
                         y: cell.maxY - half - sideUnits,
                         width: sideUnits, height: sideUnits)
        let side = sideUnits * scale

        let pocket = RoundedRectangle(cornerRadius: max(2, 16 * scale), style: .continuous)
        let cut = LinearGradient(colors: [.black.opacity(0.28), .white.opacity(0.38)],
                                 startPoint: .bottomLeading, endPoint: .topTrailing)
        // The logo itself, moulded proud of the pocket floor: a light copy
        // toward the light, a dark copy away from it, the face on top.
        let relief = max(0.6, 1.4 * scale)
        return ZStack {
            pocket
                .fill(Theme.caseEmboss)
                .overlay(pocket.strokeBorder(cut, lineWidth: max(1, 2.2 * scale)))
            glyph(side).foregroundStyle(.white.opacity(0.62)).offset(x: -relief, y: relief)
            glyph(side).foregroundStyle(.black.opacity(0.26)).offset(x: relief, y: -relief)
            glyph(side).foregroundStyle(Theme.caseEmbossFace)
        }
        .frame(width: box.width * scale, height: box.height * scale)
        .offset(x: (box.minX + bezel.side) * scale,
                y: (box.minY + bezel.top) * scale)
    }

    private func glyph(_ side: CGFloat) -> some View {
        Image(systemName: "apple.logo").font(.system(size: side * Self.glyphFill))
    }
}
