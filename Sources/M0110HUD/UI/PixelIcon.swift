import SwiftUI

/// Sidebar icons drawn pixel-by-pixel on a 16x16 grid rather than taken from SF
/// Symbols, so the navigation carries a hint of a 1-bit icon set while still
/// being tinted for the modern palette.
struct PixelIcon: View {
    enum Kind { case keys, gestures, backlight, audio, haptics, settings }
    let kind: Kind
    var tint: Color
    var size: CGFloat = 16

    var body: some View {
        Canvas { context, canvasSize in
            let u = min(canvasSize.width, canvasSize.height) / 16
            func fill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ alpha: Double = 1) {
                context.fill(Path(CGRect(x: x*u, y: y*u, width: w*u, height: h*u)),
                             with: .color(tint.opacity(alpha)))
            }
            switch kind {
            case .keys:
                // Case outline as four edges, then a grid of caps.
                fill(0, 3, 16, 1); fill(0, 12, 16, 1); fill(0, 3, 1, 10); fill(15, 3, 1, 10)
                for row in 0..<3 {
                    for col in 0..<6 { fill(2 + CGFloat(col)*2.2, 5 + CGFloat(row)*2, 1.4, 1.4, 0.85) }
                }
                fill(5, 10, 6, 1.4, 0.85)
            case .gestures:
                fill(7, 1, 2, 7)
                fill(4, 8, 8, 1); fill(4, 13, 8, 1); fill(4, 8, 1, 6); fill(11, 8, 1, 6)
                fill(6, 10, 4, 2, 0.7)
            case .backlight:
                fill(7, 7, 2, 2)
                for (dx, dy) in [(0.0, -5.0), (0.0, 5.0), (-5.0, 0.0), (5.0, 0.0),
                                 (-3.5, -3.5), (3.5, -3.5), (-3.5, 3.5), (3.5, 3.5)] {
                    fill(7.5 + dx, 7.5 + dy, 1.2, 1.2, 0.9)
                }
            case .audio:
                fill(3, 6, 3, 4); fill(6, 4, 2, 8)
                for i in 0..<3 { fill(10 + CGFloat(i)*2, 6 - CGFloat(i), 1.2, 4 + CGFloat(i)*2, 0.8) }
            case .haptics:
                for i in 0..<8 {
                    let h = CGFloat([2, 5, 9, 13, 9, 5, 2, 6][i])
                    fill(1 + CGFloat(i)*2, 8 - h/2, 1.4, h, 0.9)
                }
            case .settings:
                fill(3, 3, 10, 1); fill(3, 12, 10, 1); fill(3, 3, 1, 10); fill(12, 3, 1, 10)
                fill(5, 5.5, 6, 1.6, 0.9)
                fill(5, 9, 6, 1.6, 0.6)
            }
        }
        .frame(width: size, height: size)
    }
}
