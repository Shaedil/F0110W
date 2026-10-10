import SwiftUI

/// The M0110's underside: rubber feet, spec label, vent slots and case screws.
///
/// Positions are to scale, but the parts are drawn bigger and darker than real.
/// The board is only about 90 pt wide in the HUD, so true-size parts would be single pixels.
struct BoardUndersideView: View {
    /// Points per hundredth of a key unit.
    let scale: CGFloat

    static func size(scale: CGFloat) -> CGSize { BoardArtView.size(scale: scale) }

    var body: some View {
        let box = Self.size(scale: scale)
        Canvas { context, _ in
            let w = box.width, h = box.height
            let s = scale

            context.fill(Path(CGRect(origin: .zero, size: box)),
                         with: .color(Theme.caseFlat))

            let footInset = 168 * s, footRadius = 68 * s
            for x in [footInset, w - footInset] {
                for y in [footInset, h - footInset] {
                    let foot = CGRect(x: x - footRadius, y: y - footRadius,
                                      width: footRadius * 2, height: footRadius * 2)
                    context.fill(Path(ellipseIn: foot), with: .color(Theme.footRubber))
                    context.stroke(Path(ellipseIn: foot),
                                   with: .color(Theme.footRim), lineWidth: 5 * s)
                }
            }

            // Spec label, about two fifths of the way down like on the real case.
            let labelW = 430 * s, labelH = 150 * s
            let label = CGRect(x: (w - labelW) / 2, y: 0.38 * h - labelH / 2,
                               width: labelW, height: labelH)
            context.fill(Path(roundedRect: label, cornerRadius: 8 * s),
                         with: .color(Theme.specLabel))
            context.stroke(Path(roundedRect: label, cornerRadius: 8 * s),
                           with: .color(Theme.specLabelRim), lineWidth: 4 * s)

            // The label's text and Apple logo, drawn as bars and a dot since
            // letters don't show at this size.
            let lineX = label.minX + 22 * s
            for (i, width) in [0.62, 0.44, 0.30].enumerated() {
                let y = label.minY + (34 + CGFloat(i) * 36) * s
                let rule = CGRect(x: lineX, y: y,
                                  width: (label.width - 74 * s) * width, height: 12 * s)
                context.fill(Path(rule), with: .color(Theme.specLabelInk))
            }
            let mark = CGRect(x: label.maxX - 56 * s, y: label.minY + 46 * s,
                              width: 34 * s, height: 40 * s)
            context.fill(Path(ellipseIn: mark), with: .color(Theme.specLabelInk))

            // Vent slots near the front edge, three on each side of the center screw.
            let slotY = h - 112 * s, slotW = 130 * s, slotH = 30 * s
            let gap = 40 * s, centreGap = 110 * s
            let rowWidth = slotW * 6 + gap * 4 + centreGap
            var slotX = (w - rowWidth) / 2
            for i in 0..<6 {
                let slot = CGRect(x: slotX, y: slotY, width: slotW, height: slotH)
                context.fill(Path(roundedRect: slot, cornerRadius: slotH / 2),
                             with: .color(Theme.ventSlot))
                slotX += slotW + (i == 2 ? centreGap : gap)
            }
            func screw(at point: CGPoint, radius: CGFloat) {
                let rect = CGRect(x: point.x - radius, y: point.y - radius,
                                  width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(Theme.caseEmboss))
                context.stroke(Path(ellipseIn: rect),
                               with: .color(Theme.ventSlot), lineWidth: 5 * s)
            }
            screw(at: CGPoint(x: w / 2, y: slotY + slotH / 2), radius: 34 * s)
            // Corner screws. Keep them clear of the rim, because `BoardWedge`
            // crops anything within `BoardHull.rimWidth` of an edge.
            for x in [140 * s, w - 140 * s] {
                screw(at: CGPoint(x: x, y: h - 100 * s), radius: 28 * s)
            }
        }
        .frame(width: box.width, height: box.height)
    }
}
