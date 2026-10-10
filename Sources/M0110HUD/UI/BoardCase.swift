import SwiftUI

/// The keyboard case: a flat beige bezel around a black plate. On the M0110 the
/// Apple logo sits in a recess in the bottom-left corner, where the bottom row
/// leaves a unit empty.
///
/// Sizes are in hundredths of a key unit, the same as `DisplayKey`. The bezel is
/// a flat fill with no shading, like the matte plastic of the real case.
struct BoardCase: View {
    /// Key-field width in hundredths of a key unit (1500 for the M0110, 1960 for the A).
    let unitsWide: Int32
    /// The plate blocks the keys sit on.
    let wells: [CGRect]
    /// Notches cut out of a plate block so the bezel shows through. The M0110's
    /// bottom row is inset at both ends, and those gaps are case on the real board.
    var bezelPatches: [CGRect] = []
    /// Where the Apple logo goes, in key-field coordinates. Nil on the M0110A,
    /// whose bottom row runs the full width.
    var logoCell: CGRect?
    /// Points per hundredth of a key unit.
    let scale: CGFloat

    /// Bezel widths per variant, in hundredths of a key unit.
    struct Bezel {
        let side: CGFloat
        let top: CGFloat
        let bottom: CGFloat

        /// The compact M0110 has much wider sides than top and bottom. An even
        /// margin makes the board look too square.
        static let m0110 = Bezel(side: 125, top: 50, bottom: 50)

        /// The M0110A has an even frame. Wide sides would make it look stretched.
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

    private var shell: some View {
        shellShape
            .fill(Theme.caseFlat)
            .frame(width: box.width, height: box.height)
    }

    // MARK: - Plate

    /// Gap between neighbouring keycaps, in hundredths of a key unit. Every gap
    /// in the drawing is based on this.
    static let keyGap: CGFloat = 7

    /// How far the plate extends past the key field. Each cap already leaves half
    /// a gap inside its cell, so this makes the outer border match the gaps between caps.
    static var plateInset: CGFloat { keyGap / 2 }

    /// Corner radius for every corner of the plate outline.
    static let plateRadius: CGFloat = 13

    /// The black plate that shows in the gaps between caps.
    ///
    /// Drawn as one rounded polygon so every notch corner gets rounded. Separate
    /// overlapping shapes leave dark antialiasing seams along curved edges.
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

    /// The outline of one plate block, clockwise, in field coordinates. Only
    /// handles a notch at each bottom corner, since this board has no others.
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

    /// Size of the Apple logo as a fraction of its recess. The recess is there
    /// because a flush logo in the case color disappears. Its lower-left wall is
    /// in shadow and its upper-right wall is lit, the opposite of a raised edge.
    private static let glyphFill: CGFloat = 0.72

    /// Gap between the logo recess and its neighbouring keys. It is wider than a
    /// key gap so the logo doesn't look like a key. This only works because
    /// `M0110Layout.appleLogoCell` is square.
    private static let logoKeyGap: CGFloat = keyGap * 2

    private func appleLogo(in cell: CGRect) -> some View {
        let half = Self.keyGap / 2
        // Left edge lines up with the keys above and bottom edge with the spacebar.
        // The top and right edges clear their neighbours by `logoKeyGap`.
        let sideUnits = min(cell.width, cell.height) - Self.logoKeyGap
        let box = CGRect(x: cell.minX + half,
                         y: cell.maxY - half - sideUnits,
                         width: sideUnits, height: sideUnits)
        let side = sideUnits * scale

        let pocket = RoundedRectangle(cornerRadius: max(2, 16 * scale), style: .continuous)
        let cut = LinearGradient(colors: [.black.opacity(0.28), .white.opacity(0.38)],
                                 startPoint: .bottomLeading, endPoint: .topTrailing)
        // Raised logo: a light copy offset toward the light, a dark copy away
        // from it, then the face on top.
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
