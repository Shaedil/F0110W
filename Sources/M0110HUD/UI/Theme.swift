import AppKit
import SwiftUI

/// App colors and fonts. The background runs from near-black to beige, so content
/// sits on semi-opaque panels to keep text readable.
enum Theme {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// Background colors, from near-black to beige.
    static let ink = Color(red: 0.043, green: 0.039, blue: 0.035)
    static let inkWarm = Color(red: 0.102, green: 0.086, blue: 0.071)
    static let sienna = Color(red: 0.290, green: 0.243, blue: 0.196)
    static let beige = Color(red: 0.839, green: 0.796, blue: 0.706)

    /// Dark and semi-opaque so text stays readable over any part of the gradient.
    static let panel = dynamic(light: NSColor(white: 0.09, alpha: 0.62),
                               dark: NSColor(white: 0.07, alpha: 0.58))
    static let panelStroke = dynamic(light: NSColor(srgbRed: 0.92, green: 0.88, blue: 0.80, alpha: 0.16),
                                     dark: NSColor(srgbRed: 0.92, green: 0.88, blue: 0.80, alpha: 0.14))
    /// Glass for content panels: a few percent white, so a panel is a step lighter
    /// than the background. Same in both appearances, since the background is dark in both.
    static let glass = Color.white.opacity(0.045)
    static let glassStroke = Color.white.opacity(0.10)
    /// Floating sidebar tint, drawn over a real blur. Light mode needs nearly opaque
    /// white, because a light blur over the dark window still looks grey.
    static let sidebarFloating = dynamic(light: NSColor(white: 1, alpha: 0.96),
                                         dark: NSColor(white: 0.05, alpha: 0.38))
    static let sidebarFloatingStroke = dynamic(light: NSColor(srgbRed: 0.96, green: 0.93, blue: 0.86, alpha: 0.22),
                                               dark: NSColor(srgbRed: 0.96, green: 0.93, blue: 0.86, alpha: 0.18))

    /// Sidebar text. Light mode uses dark ink because the sidebar is white there.
    static let sidebarText = dynamic(light: NSColor(srgbRed: 0.118, green: 0.102, blue: 0.082, alpha: 0.92),
                                     dark: NSColor(srgbRed: 0.97, green: 0.955, blue: 0.925, alpha: 0.94))
    static let sidebarTextDim = dynamic(light: NSColor(srgbRed: 0.118, green: 0.102, blue: 0.082, alpha: 0.62),
                                        dark: NSColor(srgbRed: 0.97, green: 0.955, blue: 0.925, alpha: 0.52))
    /// The selected sidebar row and the toggle's keycap.
    static let sidebarKey = dynamic(light: NSColor(srgbRed: 0.118, green: 0.102, blue: 0.082, alpha: 0.08),
                                    dark: NSColor(srgbRed: 0.96, green: 0.93, blue: 0.86, alpha: 0.09))
    static let sidebarKeyStroke = dynamic(light: NSColor(srgbRed: 0.118, green: 0.102, blue: 0.082, alpha: 0.14),
                                          dark: NSColor(srgbRed: 0.96, green: 0.93, blue: 0.86, alpha: 0.18))

    /// A pane's icon tint on the sidebar, darkened in light mode so it doesn't
    /// wash out on white.
    static func sidebarIcon(_ tint: Color) -> Color {
        let base = NSColor(tint).usingColorSpace(.sRGB) ?? .gray
        let shaded = NSColor(srgbRed: base.redComponent * 0.68, green: base.greenComponent * 0.68,
                             blue: base.blueComponent * 0.68, alpha: base.alphaComponent)
        return dynamic(light: shaded, dark: base)
    }

    /// Dark beige behind the drawn board, so the beige case isn't framed in black.
    static let boardSurround = dynamic(light: NSColor(srgbRed: 0.639, green: 0.612, blue: 0.533, alpha: 0.94),
                                       dark: NSColor(srgbRed: 0.612, green: 0.588, blue: 0.510, alpha: 0.94))
    static let boardSurroundStroke = dynamic(light: NSColor(srgbRed: 0.478, green: 0.451, blue: 0.380, alpha: 0.55),
                                             dark: NSColor(srgbRed: 0.451, green: 0.427, blue: 0.357, alpha: 0.55))

    /// Pills and inactive surfaces, warm cream at low opacity.
    static let key = dynamic(light: NSColor(srgbRed: 0.96, green: 0.93, blue: 0.86, alpha: 0.10),
                             dark: NSColor(srgbRed: 0.96, green: 0.93, blue: 0.86, alpha: 0.09))
    static let keyStroke = dynamic(light: NSColor(srgbRed: 0.96, green: 0.93, blue: 0.86, alpha: 0.20),
                                   dark: NSColor(srgbRed: 0.96, green: 0.93, blue: 0.86, alpha: 0.18))
    static let keyInactive = dynamic(light: NSColor(srgbRed: 0.96, green: 0.93, blue: 0.86, alpha: 0.03),
                                     dark: NSColor(srgbRed: 0.96, green: 0.93, blue: 0.86, alpha: 0.03))

    /// Warm off-white text.
    static let text = dynamic(light: NSColor(srgbRed: 0.97, green: 0.955, blue: 0.925, alpha: 0.95),
                              dark: NSColor(srgbRed: 0.97, green: 0.955, blue: 0.925, alpha: 0.94))
    static let textDim = dynamic(light: NSColor(srgbRed: 0.97, green: 0.955, blue: 0.925, alpha: 0.55),
                                 dark: NSColor(srgbRed: 0.97, green: 0.955, blue: 0.925, alpha: 0.52))

    /// Light beige accent. Use `onAccent` for anything drawn on top of it.
    static let accent = dynamic(light: NSColor(srgbRed: 0.886, green: 0.847, blue: 0.757, alpha: 1),
                                dark: NSColor(srgbRed: 0.878, green: 0.839, blue: 0.749, alpha: 1))
    static let onAccent = Color(red: 0.118, green: 0.102, blue: 0.082)
    static let accentPale = dynamic(light: NSColor(srgbRed: 0.702, green: 0.749, blue: 0.910, alpha: 1),
                                    dark: NSColor(srgbRed: 0.235, green: 0.286, blue: 0.478, alpha: 1))

    static let good = Color(red: 0.35, green: 0.78, blue: 0.45)
    static let warn = Color(red: 0.95, green: 0.72, blue: 0.25)
    static let bad = Color(red: 0.90, green: 0.35, blue: 0.30)

    // The case is based on Pantone 453 (#BFBB98), the Apple II and Mac beige,
    // made a bit lighter and greyer to match surviving boards and to stay lighter
    // than the caps. The keycaps are Pantone Cool Gray 2 U (#C7C8BD), the color
    // of the XDA Oblique set on this board.

    /// Flat beige for the bezel.
    static let caseFlat = dynamic(light: NSColor(srgbRed: 0.855, green: 0.839, blue: 0.780, alpha: 1),
                                  dark: NSColor(srgbRed: 0.839, green: 0.824, blue: 0.765, alpha: 1))

    /// Underside parts, matched to a photo of the real case. The vents are dark
    /// because they open into the empty case.
    static let footRubber = dynamic(light: NSColor(srgbRed: 0.282, green: 0.306, blue: 0.278, alpha: 1),
                                    dark: NSColor(srgbRed: 0.259, green: 0.282, blue: 0.255, alpha: 1))
    static let footRim = dynamic(light: NSColor(srgbRed: 0.639, green: 0.627, blue: 0.576, alpha: 1),
                                 dark: NSColor(srgbRed: 0.616, green: 0.604, blue: 0.553, alpha: 1))
    static let specLabel = dynamic(light: NSColor(srgbRed: 0.945, green: 0.953, blue: 0.965, alpha: 1),
                                   dark: NSColor(srgbRed: 0.929, green: 0.937, blue: 0.949, alpha: 1))
    static let specLabelRim = dynamic(light: NSColor(srgbRed: 0.667, green: 0.678, blue: 0.690, alpha: 1),
                                      dark: NSColor(srgbRed: 0.647, green: 0.659, blue: 0.671, alpha: 1))
    static let specLabelInk = dynamic(light: NSColor(srgbRed: 0.416, green: 0.427, blue: 0.447, alpha: 1),
                                      dark: NSColor(srgbRed: 0.400, green: 0.412, blue: 0.431, alpha: 1))
    static let ventSlot = dynamic(light: NSColor(srgbRed: 0.196, green: 0.192, blue: 0.176, alpha: 1),
                                  dark: NSColor(srgbRed: 0.176, green: 0.173, blue: 0.157, alpha: 1))

    /// Back panel sockets: the recess and the darker opening inside it.
    static let portRecess = dynamic(light: NSColor(srgbRed: 0.404, green: 0.396, blue: 0.365, alpha: 1),
                                    dark: NSColor(srgbRed: 0.380, green: 0.373, blue: 0.341, alpha: 1))
    static let portMouth = dynamic(light: NSColor(srgbRed: 0.071, green: 0.067, blue: 0.059, alpha: 1),
                                   dark: NSColor(srgbRed: 0.059, green: 0.055, blue: 0.047, alpha: 1))

    /// The seam between the case shells, and the walls of the key well.
    static let caseSeam = dynamic(light: NSColor(srgbRed: 0.518, green: 0.506, blue: 0.463, alpha: 1),
                                  dark: NSColor(srgbRed: 0.494, green: 0.482, blue: 0.443, alpha: 1))

    /// The plate showing between the keycaps.
    static let plate = dynamic(light: NSColor(srgbRed: 0.075, green: 0.071, blue: 0.063, alpha: 1),
                               dark: NSColor(srgbRed: 0.063, green: 0.059, blue: 0.051, alpha: 1))

    /// Floor of the Apple logo recess, and the slightly lighter logo itself.
    static let caseEmboss = dynamic(light: NSColor(srgbRed: 0.784, green: 0.769, blue: 0.710, alpha: 1),
                                    dark: NSColor(srgbRed: 0.769, green: 0.753, blue: 0.694, alpha: 1))
    static let caseEmbossFace = dynamic(light: NSColor(srgbRed: 0.871, green: 0.855, blue: 0.796, alpha: 1),
                                        dark: NSColor(srgbRed: 0.855, green: 0.839, blue: 0.780, alpha: 1))

    /// Keycap plastic, Pantone Cool Gray 2 U: the top face and the wall below it.
    static let capTop = dynamic(light: NSColor(srgbRed: 0.796, green: 0.800, blue: 0.757, alpha: 1),
                                dark: NSColor(srgbRed: 0.780, green: 0.784, blue: 0.741, alpha: 1))
    static let capSkirt = dynamic(light: NSColor(srgbRed: 0.635, green: 0.639, blue: 0.604, alpha: 1),
                                  dark: NSColor(srgbRed: 0.620, green: 0.624, blue: 0.588, alpha: 1))

    /// The spacebar is a shade darker than the other keys on this board.
    static let spacebarTop = dynamic(light: NSColor(srgbRed: 0.729, green: 0.733, blue: 0.694, alpha: 1),
                                     dark: NSColor(srgbRed: 0.714, green: 0.718, blue: 0.678, alpha: 1))
    static let spacebarSkirt = dynamic(light: NSColor(srgbRed: 0.573, green: 0.576, blue: 0.545, alpha: 1),
                                       dark: NSColor(srgbRed: 0.557, green: 0.561, blue: 0.529, alpha: 1))

    /// Legend ink, a cool near-black. A warm brown looks painted on.
    static let capInk = Color(red: 0.243, green: 0.251, blue: 0.278)
    /// A selected cap. Amber stands out by hue, so the legend stays readable.
    static let selectedCapTop = Color(red: 0.898, green: 0.765, blue: 0.478)
    static let selectedCapSkirt = Color(red: 0.729, green: 0.573, blue: 0.290)
    static let selectedCapInk = Color(red: 0.239, green: 0.176, blue: 0.075)

    static let corner: CGFloat = 14
    static let keyCorner: CGFloat = 6

    static let pageTitle = Font.system(size: 42, weight: .regular, design: .serif)
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 12)
    static let small = Font.system(size: 11)
    /// A step above body, since macOS sidebars use larger text than content.
    static let sidebarRow = Font.system(size: 14)
    /// The Keyboard pane's toolbar, sized to match the sidebar rows.
    static let toolbar = Font.system(size: 13)

    /// Geneva, the original Mac's bitmap font. Chicago would fit better, but it
    /// doesn't ship with macOS.
    static func retro(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFontManager.shared.availableFontFamilies.contains("Geneva") {
            return .custom("Geneva", fixedSize: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }

    static let keycap = retro(11)
    static let readout = retro(11)

    /// Helvetica, the font printed on real M0110 keycaps.
    static func capLegend(_ size: CGFloat) -> Font {
        if NSFontManager.shared.availableFontFamilies.contains("Helvetica") {
            return .custom("Helvetica", fixedSize: size)
        }
        return .system(size: size)
    }

    /// 50% checkerboard pattern, used as faint grain.
    static let stipple: ImagePaint = {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        NSRect(x: 1, y: 1, width: 1, height: 1).fill()
        image.unlockFocus()
        return ImagePaint(image: Image(nsImage: image), scale: 1)
    }()
}

/// The stacked hairlines System 1 drew across its title bars.
struct RacingStripes: View {
    /// One color for every dot. If nil, the dots use the prism colors left to right.
    var colour: Color?
    @Environment(\.prism) private var prism

    var body: some View {
        Canvas { context, size in
            var dots = Path()
            for (x, y) in Self.dots(width: Int(size.width), height: Int(size.height)) {
                dots.addRect(CGRect(x: x, y: y, width: 1, height: 1))
            }
            context.fill(dots, with: colour.map { .color($0) }
                         ?? .linearGradient(Gradient(colors: prism.marks),
                                            startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
        }
        .frame(height: 13)
    }

    /// Stripes fading out to the right, Atkinson-dithered to 1 bit like MacPaint.
    /// Each pixel passes 6/8 of its error to six neighbours and drops the rest.
    private static func dots(width: Int, height: Int) -> [(Int, Int)] {
        guard width > 0, height > 0 else { return [] }
        var level = [Double](repeating: 0, count: width * height)
        for y in 0..<height where y % 3 != 2 {
            for x in 0..<width {
                level[y * width + x] = 0.9 * pow(1 - Double(x) / Double(width), 1.4)
            }
        }
        var dots: [(Int, Int)] = []
        for y in 0..<height {
            for x in 0..<width {
                let old = level[y * width + x]
                let on = old >= 0.5
                if on { dots.append((x, y)) }
                let share = (old - (on ? 1 : 0)) / 8
                for (dx, dy) in [(1, 0), (2, 0), (-1, 1), (0, 1), (1, 1), (0, 2)] {
                    let nx = x + dx, ny = y + dy
                    // Only within the stripes, so the gaps stay clear.
                    guard nx >= 0, nx < width, ny < height, ny % 3 != 2 else { continue }
                    level[ny * width + nx] += share
                }
            }
        }
        return dots
    }
}

/// A page title Atkinson-dithered to 1 bit, like the stripes next to it. It goes
/// from solid at the top of the letters to half tone at the bottom.
struct DitheredTitle: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .accessibilityLabel(text)
        } else {
            Text(text).font(Theme.pageTitle).foregroundStyle(Theme.text)
        }
    }

    @MainActor private static var cache: [String: CGImage] = [:]

    @MainActor private static func render(_ text: String) -> CGImage? {
        if let image = cache[text] { return image }
        // Render at 1 pixel per point and use the alpha as coverage.
        let renderer = ImageRenderer(content: Text(text).font(Theme.pageTitle)
                                                       .foregroundStyle(.white))
        renderer.scale = 1
        guard let mask = renderer.cgImage else { return nil }
        let width = mask.width, height = mask.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))

        var level = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            let shade = 1 - 0.5 * Double(y) / Double(max(height - 1, 1))
            for x in 0..<width {
                level[y * width + x] = Double(pixels[(y * width + x) * 4 + 3]) / 255 * shade
            }
        }
        let ink = NSColor(Theme.text).usingColorSpace(.sRGB) ?? .white
        let r = UInt8(ink.redComponent * 255), g = UInt8(ink.greenComponent * 255),
            b = UInt8(ink.blueComponent * 255)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let old = level[i]
                let on = old >= 0.5
                if on { out[i * 4] = r; out[i * 4 + 1] = g; out[i * 4 + 2] = b; out[i * 4 + 3] = 255 }
                let share = (old - (on ? 1 : 0)) / 8
                for (dx, dy) in [(1, 0), (2, 0), (-1, 1), (0, 1), (1, 1), (0, 2)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny < height else { continue }
                    level[ny * width + nx] += share
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent)
        else { return nil }
        cache[text] = image
        return image
    }
}

/// The window background: near-black with three soft glows, like prismorphism's
/// `pm-ambient-chronos`. The brightest glow follows the sun's position.
struct ThemeBackground: View {
    @Environment(\.prism) private var prism

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.ink))
            let t = prism.tints(1), cap = prism.glowScale
            let (a, b, c) = PrismTokens.ambient
            let w = size.width, h = size.height
            let sun = CGPoint(x: prism.sun.x * w, y: prism.sun.y * h)
            glow(context, at: sun, rx: 0.7 * w, ry: 0.55 * h, t[0].opacity(a * cap))
            glow(context, at: CGPoint(x: sun.x + 0.18 * w, y: sun.y + 0.12 * h),
                 rx: 0.6 * w, ry: 0.5 * h, t[1].opacity(b * cap))
            glow(context, at: CGPoint(x: 0.5 * w, y: 0.6 * h), rx: 0.8 * w, ry: 0.7 * h,
                 t[2].opacity(c * cap))
        }
        .ignoresSafeArea()
    }

    /// CSS's `radial-gradient(ellipse rx ry at x y, colour 0%, transparent 60%)`.
    private func glow(_ context: GraphicsContext, at centre: CGPoint, rx: CGFloat, ry: CGFloat,
                      _ colour: Color) {
        var context = context
        context.translateBy(x: centre.x, y: centre.y)
        context.scaleBy(x: rx, y: ry)
        context.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                     with: .radialGradient(Gradient(colors: [colour, colour.opacity(0)]),
                                           center: .zero, startRadius: 0, endRadius: 0.6))
    }
}


/// A glass card with a prism shine along its top edge, based on prismorphism's
/// `pm-glass pm-prismatic-shine`.
struct Panel<Content: View>: View {
    var padding: CGFloat = 16
    /// Top and bottom inset, if different from the sides. The board pane sets
    /// it because an even inset makes the wide board look pinched.
    var verticalPadding: CGFloat?
    var surface: Color = Theme.glass
    var stroke: Color = Theme.glassStroke
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, padding)
            .padding(.vertical, verticalPadding ?? padding)
            .background {
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .fill(surface)
                    .overlay(PrismWash(shape: RoundedRectangle(cornerRadius: Theme.corner,
                                                               style: .continuous)))
                    .overlay(
                        // Faint 1-bit grain.
                        RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                            .fill(Theme.stipple)
                            .opacity(0.045)
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            )
            .overlay(alignment: .top) { PrismShine(inset: Theme.corner) }
    }
}

/// Pill button, subtle until hovered.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    /// The default is over half any button's height, which SwiftUI clamps to a
    /// capsule. A small value gives a keycap shape.
    var cornerRadius: CGFloat = 100
    var verticalPadding: CGFloat = 5
    var font: Font = Theme.small.weight(.medium)
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return configuration.label
            .font(font)
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 12)
            .padding(.vertical, verticalPadding)
            .background {
                if prominent { PrismSelection(shape: shape) } else { shape.fill(Theme.key) }
            }
            // Faint outline, since full strength looks harsher than the fill.
            .overlay(shape.strokeBorder(prominent ? .clear : Theme.keyStroke.opacity(0.4), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.4))
    }
}

/// Segmented pill for mutually exclusive choices.
struct SegmentPills<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T
    var font: Font = Theme.small.weight(.medium)
    var padding = EdgeInsets(top: 5, leading: 11, bottom: 5, trailing: 11)

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let active = option.value == selection
                Text(option.label)
                    .font(font)
                    .foregroundStyle(active ? Theme.text : Theme.textDim)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(padding)
                    .background { if active { PrismSelection(shape: Capsule()) } }
                    .contentShape(Capsule())
                    .onTapGesture { selection = option.value }
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.key))
        .overlay(Capsule().strokeBorder(Theme.keyStroke.opacity(0.4), lineWidth: 1))
    }
}

/// True while rendering offscreen, because `ImageRenderer` can't size a `ScrollView`.
private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var classicSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

struct ClassicScroll<Content: View>: View {
    /// False skips the scroll view, for pages that fit the window.
    var scrolls = true
    @Environment(\.classicSnapshot) private var snapshot
    @ViewBuilder var content: () -> Content

    var body: some View {
        if snapshot || !scrolls {
            // Content taller than the window gets cut off instead of growing the window.
            content().frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped()
        } else {
            ScrollView { content() }
        }
    }
}

/// Slider drawn in SwiftUI. `Slider` is AppKit-backed on macOS, so it doesn't match
/// the palette and `ImageRenderer` draws it as a yellow "unsupported" bar.
struct ThemeSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0

    private let track: CGFloat = 4
    private let knob: CGFloat = 13
    @Environment(\.prism) private var prism

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - knob, 1)
            let fraction = min(max((value - range.lowerBound)
                                   / (range.upperBound - range.lowerBound), 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.key)
                    .overlay(Capsule().strokeBorder(Theme.keyStroke, lineWidth: 1))
                    .frame(height: track)
                // Prism gradient across the filled part, like prismorphism's progress bars.
                Capsule()
                    .fill(LinearGradient(colors: prism.marks, startPoint: .leading, endPoint: .trailing))
                    .frame(width: knob / 2 + usable * fraction, height: track)
                Circle()
                    .fill(Theme.text)
                    .overlay(Circle().strokeBorder(.black.opacity(0.30), lineWidth: 1))
                    .frame(width: knob, height: knob)
                    .offset(x: usable * fraction)
            }
            .frame(height: knob)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let raw = (drag.location.x - knob / 2) / usable
                        set(fraction: raw)
                    }
            )
        }
        .frame(height: knob)
    }

    private func set(fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        var next = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
        if step > 0 { next = (next / step).rounded() * step }
        value = min(max(next, range.lowerBound), range.upperBound)
    }
}

/// Minus/plus pair, replacing AppKit's `Stepper`.
struct ThemeStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 4) {
            button("\u{2212}") { value = max(range.lowerBound, value - 1) }
            button("+") { value = min(range.upperBound, value + 1) }
        }
    }

    private func button(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.small.weight(.semibold))
                .frame(width: 20, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .background(Theme.key, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Theme.keyStroke, lineWidth: 1)
        )
    }
}

/// Switch drawn in SwiftUI, for the same reasons as `ThemeSlider`.
struct ThemeSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.prism) private var prism

    var body: some View {
        Capsule()
            .fill(isOn
                  ? AnyShapeStyle(LinearGradient(colors: prism.marks.map { $0.opacity(0.85) },
                                                 startPoint: .leading, endPoint: .trailing))
                  : AnyShapeStyle(Theme.key))
            .overlay(Capsule().strokeBorder(isOn ? .clear : Theme.keyStroke, lineWidth: 1))
            .frame(width: 32, height: 18)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white.opacity(isOn ? 1 : 0.85))
                    .frame(width: 14, height: 14)
                    .padding(2)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            }
            .contentShape(Capsule())
            .onTapGesture { isOn.toggle() }
            .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

/// AppKit blur for the floating sidebar. SwiftUI materials turn flat grey over
/// this dark background, but `NSVisualEffectView` in `.withinWindow` mode blurs it.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}
