import AppKit
import SwiftUI

/// The M0110 drawn top-down with the same `BoardCase` and `Keycap` the Keys pane uses.
/// Caps are blank because legends turn into grey noise at the sizes this is shown.
struct BoardArtView: View {
    /// Points per hundredth of a key unit.
    let scale: CGFloat

    private static let well = CGRect(x: 0, y: 0, width: 1500, height: 500)
    private static let bezelPatches = M0110Layout.bezelPatches

    static func size(scale: CGFloat) -> CGSize {
        BoardCase.size(unitsWide: M0110Layout.unitsWide, bezel: .m0110, scale: scale)
    }

    var body: some View {
        let originX = BoardCase.Bezel.m0110.side * scale
        let originY = BoardCase.Bezel.m0110.top * scale
        let box = Self.size(scale: scale)

        ZStack(alignment: .topLeading) {
            BoardCase(unitsWide: M0110Layout.unitsWide,
                      wells: [Self.well],
                      bezelPatches: Self.bezelPatches,
                      logoCell: M0110Layout.appleLogoCell,
                      scale: scale)
            caps(originX: originX, originY: originY)
        }
        .frame(width: box.width, height: box.height, alignment: .topLeading)
    }

    private func caps(originX: CGFloat, originY: CGFloat) -> some View {
        let gap = BoardCase.keyGap * scale
        return ForEach(Array(M0110Layout.ansi.enumerated()), id: \.offset) { _, key in
            Keycap(legend: .blank,
                   isSelected: false,
                   isEditable: true,
                   isSpacebar: key.position == M0110Layout.spacebarPosition,
                   scale: scale)
                .frame(width: CGFloat(key.attrs.width) * scale - gap,
                       height: CGFloat(key.attrs.height) * scale - gap)
                .offset(x: originX + CGFloat(key.attrs.x) * scale + gap / 2,
                        y: originY + CGFloat(key.attrs.y) * scale + gap / 2)
        }
    }
}

/// Board art rendered to cached images.
@MainActor
enum BoardArt {
    private struct CacheKey: Hashable {
        let pixelsWide: Int
        let isDark: Bool
        let face: Face
    }

    private enum Face: Hashable { case top, underside, back }
    private static var cache: [CacheKey: NSImage] = [:]

    /// The board's top face at about `pixelsWide` across. Cached because the main
    /// caller asks for it on the main thread right when the keyboard connects.
    /// `colorScheme` must be passed in since an offscreen render has no window to
    /// take it from.
    static func topFace(pixelsWide: CGFloat, colorScheme: ColorScheme) -> NSImage? {
        let key = CacheKey(pixelsWide: Int(pixelsWide), isDark: colorScheme == .dark,
                           face: .top)
        if let hit = cache[key] { return hit }

        let started = Date()
        let span = CGFloat(M0110Layout.unitsWide) + BoardCase.Bezel.m0110.side * 2
        let scale = (pixelsWide / 2) / span

        let renderer = ImageRenderer(
            content: BoardArtView(scale: scale)
                .environment(\.colorScheme, colorScheme))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }

        cache[key] = image
        if ProcessInfo.processInfo.arguments.contains("--verbose") {
            print(String(format: "[art] board texture %.0fpx %@ rendered in %.0f ms",
                         pixelsWide, colorScheme == .dark ? "dark" : "light",
                         Date().timeIntervalSince(started) * 1000))
        }
        return image
    }

    /// The board's underside. Cached like the top face, since the HUD shows it
    /// within a second of appearing.
    static func bottomFace(pixelsWide: CGFloat, colorScheme: ColorScheme) -> NSImage? {
        let key = CacheKey(pixelsWide: Int(pixelsWide), isDark: colorScheme == .dark,
                           face: .underside)
        if let hit = cache[key] { return hit }

        let span = CGFloat(M0110Layout.unitsWide) + BoardCase.Bezel.m0110.side * 2
        let scale = (pixelsWide / 2) / span

        let renderer = ImageRenderer(
            content: BoardUndersideView(scale: scale)
                .environment(\.colorScheme, colorScheme))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }

        cache[key] = image
        return image
    }

    static func backFace(pixelsWide: CGFloat, colorScheme: ColorScheme) -> NSImage? {
        let key = CacheKey(pixelsWide: Int(pixelsWide), isDark: colorScheme == .dark,
                           face: .back)
        if let hit = cache[key] { return hit }

        let hull = BoardHull.m0110
        let span = CGSize(width: hull.footprint.width,
                          height: hull.backHeight - hull.rimDrop)
        let scale = (pixelsWide / 2) / span.width

        let renderer = ImageRenderer(
            content: BoardBackView(scale: scale, span: span)
                .environment(\.colorScheme, colorScheme))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }

        cache[key] = image
        return image
    }

    /// Renders every face before the first HUD so the cost isn't paid at connect time.
    static func warm(pixelsWide: CGFloat, colorScheme: ColorScheme) {
        _ = topFace(pixelsWide: pixelsWide, colorScheme: colorScheme)
        _ = bottomFace(pixelsWide: pixelsWide, colorScheme: colorScheme)
        _ = backFace(pixelsWide: pixelsWide, colorScheme: colorScheme)
    }
}
