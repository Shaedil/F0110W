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
    var glyphWidth: CGFloat { 46 * scale }
    var glyphHeight: CGFloat { glyphWidth / 1.45 }

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
