import AppKit
import SwiftUI

/// The M0110 drawn top-down as one piece of vector art, with no editor
/// behaviour attached: the same `BoardCase` and the same `Keycap` the Keys pane
/// uses, so there is one drawing of this keyboard in the app rather than a
/// detailed one for the editor and a cartoon for everywhere else.
///
/// The caps are blank. This view has no keymap behind it, and at the size it
/// gets used, a HUD glyph or a texture on a spinning solid, lettering resolves
/// to grey noise and reads worse than a clean cap anyway.
struct BoardArtView: View {
    /// Points per unit-hundredth.
    let scale: CGFloat

    private static let well = CGRect(x: 0, y: 0, width: 1500, height: 500)
    /// Same two gaps `KeyboardController.boardBezelPatches` describes.
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
        // Same gap the editor leaves between caps.
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

/// Rasterised board art, for anything that needs the drawing as an image.
@MainActor
enum BoardArt {
    private struct CacheKey: Hashable {
        let pixelsWide: Int
        let isDark: Bool
        let face: Face
    }

    private enum Face: Hashable { case top, underside, back }
    private static var cache: [CacheKey: NSImage] = [:]

    /// The board's top face at roughly `pixelsWide` across.
    ///
    /// Cached, because the one caller that matters asks for it on the main
    /// thread at the moment the keyboard connects, which is the worst possible
    /// time to rasterise sixty keycaps. The art has no state, so the same
    /// appearance always yields the same image and a second HUD costs nothing.
    ///
    /// `colorScheme` has to be passed explicitly: SwiftUI resolves the dynamic
    /// palette from the environment, and an offscreen render has no window to
    /// inherit one from. `Snapshot` sets it for the same reason.
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

    /// The board's underside, cached on the same terms as the top.
    ///
    /// Much cheaper to draw than the top face — a handful of shapes against
    /// sixty keycaps — but it goes through the same cache because it is wanted
    /// at the same moment, and a roll shows it within a second of the HUD
    /// appearing.
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

    /// The board's back face, cached on the same terms.
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

    /// Rasterise ahead of the first HUD, so the cost is not paid at connect
    /// time. Cheap to call twice; the second one is a cache hit.
    static func warm(pixelsWide: CGFloat, colorScheme: ColorScheme) {
        _ = topFace(pixelsWide: pixelsWide, colorScheme: colorScheme)
        _ = bottomFace(pixelsWide: pixelsWide, colorScheme: colorScheme)
        _ = backFace(pixelsWide: pixelsWide, colorScheme: colorScheme)
    }
}
