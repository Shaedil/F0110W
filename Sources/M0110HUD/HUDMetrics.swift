import CoreGraphics

/// Every HUD dimension, from one scale factor so `--scale` resizes it without re-tuning.
/// Sizes match the 13 pt menu bar text: the title is the same size, and the status line
/// and ring label are one step smaller.
struct HUDMetrics {
    var scale: CGFloat = 1

    var height: CGFloat { 46 * scale }
    var cornerRadius: CGFloat { height / 2 }

    /// The slot the board rotates in. Squarer than the board's 2.6:1 footprint because a
    /// rotating solid sweeps its depth through the frame. The camera fixes its horizontal field
    /// of view, so widening the slot is what enlarges the board. Scaling the node as well would
    /// clip its ends.
    var glyphWidth: CGFloat { 92 * scale }

    /// The slot's 1.45 aspect, capped at the capsule height. At 1.5x scale the height would pass
    /// 46 pt and the constraints could not be met. The roll's vertical sweep is much shorter than
    /// its width, so it still fits.
    var glyphHeight: CGFloat { min(glyphWidth / 1.45, height) }

    var titleSize: CGFloat { 13 * scale }
    var statusSize: CGFloat { 11 * scale }

    var ringDiameter: CGFloat { 33 * scale }
    var ringLineWidth: CGFloat { 4 * scale }
    var ringFontSize: CGFloat { 11 * scale }

    /// Wider than the trailing inset because the capsule end is a semicircle. A rectangular glyph
    /// hits it at the corners, while the round ring on the right follows the curve.
    var padLeading: CGFloat { 13 * scale }
    var padTrailing: CGFloat { 8 * scale }
    var gap: CGFloat { 12 * scale }

    var minWidth: CGFloat { 208 * scale }
    var maxWidth: CGFloat { 360 * scale }

    /// macOS anchors its own popup under the device's menu bar item. This roughly matches that
    /// without taking a menu bar slot.
    var insetX: CGFloat = 110
    var insetY: CGFloat = 6
}
