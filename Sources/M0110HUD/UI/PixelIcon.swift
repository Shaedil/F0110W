import SwiftUI

/// Sidebar icons drawn pixel-by-pixel on a 16x16 grid rather than taken from SF
/// Symbols, so the navigation carries a hint of a 1-bit icon set while still
/// being tinted for the modern palette.
struct PixelIcon: View {
    enum Kind { case keys, bluetooth, battery, gestures, settings }
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
            case .bluetooth:
                // The rune: a spine with two chevrons off its right side.
                fill(7, 1, 1.6, 14)
                fill(8.6, 2, 1.4, 1.4); fill(10, 3.4, 1.4, 1.4); fill(11.4, 4.8, 1.4, 1.4)
                fill(10, 6.2, 1.4, 1.4); fill(8.6, 7.6, 1.4, 1.4)
                fill(10, 9, 1.4, 1.4); fill(11.4, 10.4, 1.4, 1.4); fill(10, 11.8, 1.4, 1.4)
                fill(8.6, 13.2, 1.4, 1.4)
                fill(5.6, 4.8, 1.4, 1.4, 0.8); fill(4.2, 3.4, 1.4, 1.4, 0.8)
                fill(5.6, 10.4, 1.4, 1.4, 0.8); fill(4.2, 11.8, 1.4, 1.4, 0.8)
            case .battery:
                // Outline, terminal nub, and a charge three-quarters full.
                fill(1, 4, 12, 1); fill(1, 11, 12, 1); fill(1, 4, 1, 8); fill(12, 4, 1, 8)
                fill(13, 6, 2, 4)
                fill(3, 6, 6.5, 4, 0.85)
            case .gestures:
                fill(7, 1, 2, 7)
                fill(4, 8, 8, 1); fill(4, 13, 8, 1); fill(4, 8, 1, 6); fill(11, 8, 1, 6)
                fill(6, 10, 4, 2, 0.7)
            case .settings:
                fill(3, 3, 10, 1); fill(3, 12, 10, 1); fill(3, 3, 1, 10); fill(12, 3, 1, 10)
                fill(5, 5.5, 6, 1.6, 0.9)
                fill(5, 9, 6, 1.6, 0.6)
            }
        }
        .frame(width: size, height: size)
    }
}
