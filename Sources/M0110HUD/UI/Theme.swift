import AppKit
import SwiftUI

/// Black graded into classic Macintosh beige, with translucent dark panels and a
/// serif page title.
///
/// Because the ground runs from near-black to beige, no single ink colour is
/// legible across all of it, so content sits on its own semi-opaque surfaces
/// and takes its contrast from those rather than from the gradient behind.
enum Theme {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// Near-black through warm browns into Platinum-era beige.
    static let ink = Color(red: 0.043, green: 0.039, blue: 0.035)
    static let inkWarm = Color(red: 0.102, green: 0.086, blue: 0.071)
    static let sienna = Color(red: 0.290, green: 0.243, blue: 0.196)
    static let beige = Color(red: 0.839, green: 0.796, blue: 0.706)

    /// Panels stay dark and semi-opaque so text keeps its contrast wherever the
    /// gradient happens to be beneath them.
    static let panel = dynamic(light: NSColor(white: 0.09, alpha: 0.62),
                               dark: NSColor(white: 0.07, alpha: 0.58))
    static let panelStroke = dynamic(light: NSColor(srgbRed: 0.92, green: 0.88, blue: 0.80, alpha: 0.16),
                                     dark: NSColor(srgbRed: 0.92, green: 0.88, blue: 0.80, alpha: 0.14))
    /// The floating sidebar's tint, laid over a real blur, so it is much more
    /// transparent than the docked sidebar it replaced: the blur supplies the
    /// separation that opacity used to.
    static let sidebarFloating = dynamic(light: NSColor(white: 0.07, alpha: 0.42),
                                         dark: NSColor(white: 0.05, alpha: 0.38))
    static let sidebarFloatingStroke = dynamic(light: NSColor(srgbRed: 0.96, green: 0.93, blue: 0.86, alpha: 0.22),
                                               dark: NSColor(srgbRed: 0.96, green: 0.93, blue: 0.86, alpha: 0.18))

    /// The surround the drawn board sits in: a dark *beige*. The near-black
    /// panel used everywhere else was the last black object left next to an
    /// all-beige keyboard, and it framed the case like a photograph rather than
    /// being part of the same object family.
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

    /// Warm off-white, so the ink leans beige rather than clinical grey.
    static let text = dynamic(light: NSColor(srgbRed: 0.97, green: 0.955, blue: 0.925, alpha: 0.95),
                              dark: NSColor(srgbRed: 0.97, green: 0.955, blue: 0.925, alpha: 0.94))
    static let textDim = dynamic(light: NSColor(srgbRed: 0.97, green: 0.955, blue: 0.925, alpha: 0.55),
                                 dark: NSColor(srgbRed: 0.97, green: 0.955, blue: 0.925, alpha: 0.52))

    /// Beige, the same family as the gradient's warm end.
    ///
    /// Being a light accent, anything sitting on it needs dark ink rather than
    /// white, which is what `onAccent` is for.
    static let accent = dynamic(light: NSColor(srgbRed: 0.886, green: 0.847, blue: 0.757, alpha: 1),
                                dark: NSColor(srgbRed: 0.878, green: 0.839, blue: 0.749, alpha: 1))
    static let onAccent = Color(red: 0.118, green: 0.102, blue: 0.082)
    static let accentPale = dynamic(light: NSColor(srgbRed: 0.702, green: 0.749, blue: 0.910, alpha: 1),
                                    dark: NSColor(srgbRed: 0.235, green: 0.286, blue: 0.478, alpha: 1))

    static let good = Color(red: 0.35, green: 0.78, blue: 0.45)
    static let warn = Color(red: 0.95, green: 0.72, blue: 0.25)
    static let bad = Color(red: 0.90, green: 0.35, blue: 0.30)

    // ## Colour sources
    //
    // The case is Apple Beige, sourced from **Pantone 453** (#BFBB98), Jerry
    // Manock's spec for both the Apple II and the Macintosh. It is used here
    // lifted and desaturated a little: 453 straight is distinctly olive, while
    // surviving boards read lighter and greyer, and the bezel has to stay
    // clearly lighter than the caps.
    //
    // The keycaps are **Pantone Cool Gray 2 U** (#C7C8BD), which is the colour
    // of the XDA Oblique set, an AEK-style keyset in a uniform XDA profile.
    // That is the "industrial beige-grey": all but neutral, with a faint green
    // cast, against a warm case. The original Apple caps were a warmer
    // brown-grey; Cool Gray 2 is what is on this board.
    //
    // Between them sits the plate, which is black. It is the only thing in the
    // drawing giving the caps a hard edge now that the bezel is flat.

    /// The bezel: one flat beige, slightly darker than the caps are light.
    static let caseFlat = dynamic(light: NSColor(srgbRed: 0.855, green: 0.839, blue: 0.780, alpha: 1),
                                  dark: NSColor(srgbRed: 0.839, green: 0.824, blue: 0.765, alpha: 1))

    /// The underside's fittings, all from the reference photograph of the real
    /// case. The feet are the grey-green translucent rubber Apple used, seated
    /// in a moulded well; the label is the silver foil spec plate; the vents
    /// read as shadow rather than as plastic, because that is what a slot into
    /// an empty case looks like.
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

    /// The front face's sockets: the moulded recess, and the darker mouth of
    /// the socket sitting inside it. Both read as shadow, because an opening
    /// into an empty case is what they are.
    static let portRecess = dynamic(light: NSColor(srgbRed: 0.404, green: 0.396, blue: 0.365, alpha: 1),
                                    dark: NSColor(srgbRed: 0.380, green: 0.373, blue: 0.341, alpha: 1))
    static let portMouth = dynamic(light: NSColor(srgbRed: 0.071, green: 0.067, blue: 0.059, alpha: 1),
                                   dark: NSColor(srgbRed: 0.059, green: 0.055, blue: 0.047, alpha: 1))

    /// The line where the case's two shells meet, and the shadowed walls of
    /// the key well. Both are seen, not lit: a groove and a recess.
    static let caseSeam = dynamic(light: NSColor(srgbRed: 0.518, green: 0.506, blue: 0.463, alpha: 1),
                                  dark: NSColor(srgbRed: 0.494, green: 0.482, blue: 0.443, alpha: 1))

    /// The plate showing between the keycaps.
    static let plate = dynamic(light: NSColor(srgbRed: 0.075, green: 0.071, blue: 0.063, alpha: 1),
                               dark: NSColor(srgbRed: 0.063, green: 0.059, blue: 0.051, alpha: 1))

    /// The floor of the Apple logo pocket, and the beige the logo is moulded
    /// in, a shade above it.
    static let caseEmboss = dynamic(light: NSColor(srgbRed: 0.784, green: 0.769, blue: 0.710, alpha: 1),
                                    dark: NSColor(srgbRed: 0.769, green: 0.753, blue: 0.694, alpha: 1))
    static let caseEmbossFace = dynamic(light: NSColor(srgbRed: 0.871, green: 0.855, blue: 0.796, alpha: 1),
                                        dark: NSColor(srgbRed: 0.855, green: 0.839, blue: 0.780, alpha: 1))

    /// Keycap plastic: Pantone Cool Gray 2 U. `capTop` is the top face's own
    /// colour, with the sheen laid over it doing the modelling, and `capSkirt`
    /// the wall below it.
    static let capTop = dynamic(light: NSColor(srgbRed: 0.796, green: 0.800, blue: 0.757, alpha: 1),
                                dark: NSColor(srgbRed: 0.780, green: 0.784, blue: 0.741, alpha: 1))
    static let capSkirt = dynamic(light: NSColor(srgbRed: 0.635, green: 0.639, blue: 0.604, alpha: 1),
                                  dark: NSColor(srgbRed: 0.620, green: 0.624, blue: 0.588, alpha: 1))

    /// The spacebar is moulded a shade darker than the alphas on this board.
    static let spacebarTop = dynamic(light: NSColor(srgbRed: 0.729, green: 0.733, blue: 0.694, alpha: 1),
                                     dark: NSColor(srgbRed: 0.714, green: 0.718, blue: 0.678, alpha: 1))
    static let spacebarSkirt = dynamic(light: NSColor(srgbRed: 0.573, green: 0.576, blue: 0.545, alpha: 1),
                                       dark: NSColor(srgbRed: 0.557, green: 0.561, blue: 0.529, alpha: 1))

    /// Legend ink. The board prints in a cool near-black that goes slate
    /// against the plastic; a warm brown ink looks painted on rather than
    /// moulded.
    static let capInk = Color(red: 0.243, green: 0.251, blue: 0.278)
    /// A selected cap. Amber separates from every other cap by hue rather than
    /// by darkness, which keeps it legible without introducing a second black.
    static let selectedCapTop = Color(red: 0.898, green: 0.765, blue: 0.478)
    static let selectedCapSkirt = Color(red: 0.729, green: 0.573, blue: 0.290)
    static let selectedCapInk = Color(red: 0.239, green: 0.176, blue: 0.075)

    static let corner: CGFloat = 14
    static let keyCorner: CGFloat = 6

    static let pageTitle = Font.system(size: 42, weight: .regular, design: .serif)
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 12)
    static let small = Font.system(size: 11)

    /// Geneva, the bitmap face that shipped with the Mac this keyboard came
    /// with. Used where the period matters: keycap legends and small readouts.
    /// Chicago was the System font but Apple has never shipped it.
    static func retro(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFontManager.shared.availableFontFamilies.contains("Geneva") {
            return .custom("Geneva", fixedSize: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }

    static let keycap = retro(11)
    static let readout = retro(11)

    /// Helvetica, which is what is printed on an M0110's keycaps. The app's own
    /// chrome stays on Geneva, so the board is lettered like the board rather
    /// than like the app around it.
    static func capLegend(_ size: CGFloat) -> Font {
        if NSFontManager.shared.availableFontFamilies.contains("Helvetica") {
            return .custom("Helvetica", fixedSize: size)
        }
        return .system(size: size)
    }

    /// Faint 50% stipple, the 1-bit stand-in for grey, used here as grain.
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
    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { _ in
                Rectangle().fill(Theme.textDim.opacity(0.45)).frame(height: 1)
            }
        }
        .frame(height: 13)
    }
}

/// Near-black graded diagonally into beige, top-left to bottom-right. Weighted
/// so most of the canvas stays dark and the beige arrives in the lower-right,
/// where little content sits.
struct ThemeBackground: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Theme.ink, location: 0.00),
                .init(color: Theme.inkWarm, location: 0.34),
                .init(color: Theme.sienna, location: 0.62),
                .init(color: Theme.beige, location: 0.94),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}


/// Translucent rounded card.
struct Panel<Content: View>: View {
    var padding: CGFloat = 16
    /// Top and bottom inset, when it should differ from the sides. The board
    /// pane uses this: its surround reads as part of the keyboard's framing,
    /// and an even inset around a board that is three times wider than tall
    /// leaves the top and bottom looking pinched.
    var verticalPadding: CGFloat?
    /// Surface colour. Defaults to the app's near-black panel; the board pane
    /// overrides it so the keyboard is not framed in black.
    var surface: Color = Theme.panel
    var stroke: Color = Theme.panelStroke
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, padding)
            .padding(.vertical, verticalPadding ?? padding)
            .background {
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .fill(surface)
                    .overlay(
                        // 1-bit grain, barely there, to keep the surface from
                        // reading as flat modern glass.
                        RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                            .fill(Theme.stipple)
                            .opacity(0.045)
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            )
    }
}

/// Pill button, subtle until hovered.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.small.weight(.medium))
            .foregroundStyle(prominent ? Theme.onAccent : Theme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(prominent
                               ? AnyShapeStyle(Theme.accent)
                               : AnyShapeStyle(Theme.key))
            )
            .overlay(Capsule().strokeBorder(prominent ? .clear : Theme.keyStroke, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.4))
    }
}

/// Segmented pill for mutually exclusive choices.
struct SegmentPills<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let active = option.value == selection
                Text(option.label)
                    .font(Theme.small.weight(.medium))
                    .foregroundStyle(active ? Theme.onAccent : Theme.textDim)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.clear))
                    )
                    .contentShape(Capsule())
                    .onTapGesture { selection = option.value }
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.key))
        .overlay(Capsule().strokeBorder(Theme.keyStroke, lineWidth: 1))
    }
}

/// True while rendering offscreen; `ImageRenderer` cannot size a `ScrollView`.
private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var classicSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

struct ClassicScroll<Content: View>: View {
    @Environment(\.classicSnapshot) private var snapshot
    @ViewBuilder var content: () -> Content

    var body: some View {
        if snapshot { content() } else { ScrollView { content() } }
    }
}

/// Slider drawn in SwiftUI rather than using AppKit's.
///
/// Aqua's control does not match this palette, and `Slider` is AppKit-backed on
/// macOS so `ImageRenderer` cannot rasterise it: offscreen snapshots showed it
/// as a yellow "unsupported" bar.
struct ThemeSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0

    private let track: CGFloat = 4
    private let knob: CGFloat = 13

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
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: knob / 2 + usable * fraction, height: track)
                Circle()
                    .fill(Theme.accent)
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

    var body: some View {
        Capsule()
            .fill(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.key))
            .overlay(Capsule().strokeBorder(isOn ? .clear : Theme.keyStroke, lineWidth: 1))
            .frame(width: 32, height: 18)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? Theme.onAccent : Color.white.opacity(0.85))
                    .frame(width: 14, height: 14)
                    .padding(2)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            }
            .contentShape(Capsule())
            .onTapGesture { isOn.toggle() }
            .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

/// AppKit's blur, for the floating sidebar.
///
/// SwiftUI's materials sample the window's backing and, over this theme's
/// near-black gradient, resolve to a flat grey. `NSVisualEffectView` in
/// `.withinWindow` mode blurs what is behind it.
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
