import CoreGraphics

/// Every dimension the HUD uses, derived from one scale factor so the whole
/// thing can be resized with `--scale` without re-tuning the layout.
///
/// Sizes are calibrated against the macOS menu bar, whose text is 13pt: the
/// title matches it, the status line and ring label sit one step below.
struct HUDMetrics {
    var scale: CGFloat = 1

    var height: CGFloat { 46 * scale }
    var cornerRadius: CGFloat { height / 2 }

    /// The slot the board turns in. Squarer than the board's own 2.6:1
    /// footprint on purpose: a rotating solid sweeps its depth through the
    /// frame, and a slot cut to the head-on silhouette clips the corners for
    /// most of every turn.
    ///
    /// 92, twice the 46 it started at, and that factor is also how much bigger
    /// the board itself draws. The scene camera fixes its *horizontal* field of view, so the
    /// board fills a constant fraction of the slot however wide the slot is:
    /// widening the slot is what enlarges the model, and scaling the model node
    /// as well would compound the two and shear its ends off against the edge.
    ///
    /// The first 23pt of that came free: `minWidth` used to be the binding
    /// constraint, stretching the text stack past the 61.5pt its labels
    /// actually want, and the glyph took that slack. Past 69 the capsule does
    /// grow, to about 231.
    var glyphWidth: CGFloat { 92 * scale }

    /// The slot's 1.45 aspect, but never taller than the capsule holding it.
    /// At 1.5× the derived height passes the HUD's own 46pt, which is an
    /// unsatisfiable pair of constraints rather than a bigger glyph. Clamping
    /// squares the slot up instead, and the roll's vertical sweep is far
    /// shorter than its width, so it still has room.
    var glyphHeight: CGFloat { min(glyphWidth / 1.45, height) }

    var titleSize: CGFloat { 13 * scale }
    var statusSize: CGFloat { 11 * scale }

    var ringDiameter: CGFloat { 33 * scale }
    var ringLineWidth: CGFloat { 4 * scale }
    var ringFontSize: CGFloat { 11 * scale }

    /// Wider than the trailing inset on purpose. The capsule end is a
    /// semicircle, so a rectangular glyph is tightest at its corners rather than
    /// its middle, while the circular ring on the right follows the curve.
    var padLeading: CGFloat { 13 * scale }
    var padTrailing: CGFloat { 8 * scale }
    var gap: CGFloat { 12 * scale }

    var minWidth: CGFloat { 208 * scale }
    var maxWidth: CGFloat { 360 * scale }

    /// Inset of the HUD's right edge from the right screen edge. macOS anchors
    /// its own popup under the device's menu bar item rather than the screen
    /// corner; this approximates that without claiming a menu bar slot.
    var insetX: CGFloat = 110
    /// Gap below the menu bar.
    var insetY: CGFloat = 6
}
