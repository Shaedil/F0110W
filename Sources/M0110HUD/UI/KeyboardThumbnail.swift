import SwiftUI

/// Small copy of the board for the sidebar header, drawn from the same
/// `DisplayKey` table as the Keys pane so it always matches.
struct KeyboardThumbnail: View {
    let keys: [DisplayKey]
    /// Board width in hundredths of a key unit.
    let unitsWide: Int32
    var tint: Color

    private var unitsTall: Int32 {
        max(keys.reduce(100) { max($0, $1.attrs.y + $1.attrs.height) }, 100)
    }

    var body: some View {
        Canvas { context, size in
            guard unitsWide > 0 else { return }
            let scale = size.width / CGFloat(unitsWide)
            let gap = max(0.6, 8 * scale)
            for key in keys {
                let rect = CGRect(x: CGFloat(key.attrs.x) * scale + gap / 2,
                                  y: CGFloat(key.attrs.y) * scale + gap / 2,
                                  width: CGFloat(key.attrs.width) * scale - gap,
                                  height: CGFloat(key.attrs.height) * scale - gap)
                guard rect.width > 0.4, rect.height > 0.4 else { continue }
                context.fill(Path(roundedRect: rect, cornerRadius: max(0.5, 1.6 * scale * 100)),
                             with: .color(tint))
            }
        }
        .aspectRatio(CGFloat(unitsWide) / CGFloat(unitsTall), contentMode: .fit)
    }
}
