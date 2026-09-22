import SwiftUI

/// The M0110's underside, drawn in the same vector-art register as the top.
///
/// Half of every barrel roll shows this face, and until it existed that half
/// was a blank cream slab. Drawn from the reference photograph of the real
/// case: four rubber feet at the corners, the silver spec label across the
/// middle, and the row of vent slots near the front edge with the case screw
/// sitting in the middle of it.
///
/// Everything is deliberately coarse, and every fitting is drawn larger and
/// darker than it measures. The board is about 90pt across in the HUD, so a
/// screw at its true 2.3% of the width lands on a single pixel and the whole
/// face collapses back to a blank slab. What has to survive at that size is the
/// *arrangement* — feet at the corners, a label in the middle, a line of slots
/// across the front — so the arrangement is drawn to scale and the parts are
/// drawn to be seen. Same trade as `BoardHull.rimDrop`.
struct BoardUndersideView: View {
    /// Points per unit-hundredth, the same convention `BoardArtView` uses.
    let scale: CGFloat

    /// The face is the board's whole footprint, so it matches the top exactly.
    static func size(scale: CGFloat) -> CGSize { BoardArtView.size(scale: scale) }

    var body: some View {
        let box = Self.size(scale: scale)
        Canvas { context, _ in
            let w = box.width, h = box.height
            let s = scale

            // The case, a shade below the top's bezel: this side is unlit
            // moulded plastic that never had a texture pass over it.
            context.fill(Path(CGRect(origin: .zero, size: box)),
                         with: .color(Theme.caseFlat))

            // Four rubber feet, inset from the corners. Darker and greyer than
            // anything else down here, which is what picks the corners out when
            // the face is only a few dozen points across.
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

            // The spec label: silver, wider than it is tall, and sitting back
            // of centre rather than on it -- in the reference it is nearer the
            // connector end than the vents, about two fifths down.
            let labelW = 430 * s, labelH = 150 * s
            let label = CGRect(x: (w - labelW) / 2, y: 0.38 * h - labelH / 2,
                               width: labelW, height: labelH)
            context.fill(Path(roundedRect: label, cornerRadius: 8 * s),
                         with: .color(Theme.specLabel))
            context.stroke(Path(roundedRect: label, cornerRadius: 8 * s),
                           with: .color(Theme.specLabelRim), lineWidth: 4 * s)

            // Its print, as rules rather than letters. Three short lines and
            // the Apple mark's blot, which is all that resolves at glyph size.
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

            // Vent slots along the front edge: three either side of a wider
            // centre gap, with the case screw sitting in that gap. The screw
            // interrupts the row rather than being laid over a slot.
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
            // Two more hold the case together near the front corners. Kept
            // clear of the rim: `BoardWedge` crops this drawing to the raised
            // platform, so anything within `BoardHull.rimWidth` of an edge is
            // never seen.
            for x in [140 * s, w - 140 * s] {
                screw(at: CGPoint(x: x, y: h - 100 * s), radius: 28 * s)
            }
        }
        .frame(width: box.width, height: box.height)
    }
}
