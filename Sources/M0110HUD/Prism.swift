import SwiftUI

/// The window's three-color palette for one moment, from `Chronos` (prismorphism's color layer).
/// `tints` are for glows, rims and washes, and `marks` for things that show a value (slider
/// fill, an on switch, page stripes). The original's night navy is invisible on a near-black
/// window, so both keep the sky's hues but clamp lightness and add a minimum saturation.
struct PrismPalette: Equatable {
    var state: Chronos.State

    init(_ state: Chronos.State = Chronos.noon) { self.state = state }

    static func at(_ date: Date) -> PrismPalette { PrismPalette(Chronos.state(at: date)) }

    /// 0...1, low at night.
    var glowCap: Double { state.glowCap }

    /// The original scales glows by the glow cap directly, which leaves a third at night. This
    /// keeps night calmer but still colored.
    var glowScale: Double { 0.6 + 0.4 * glowCap }

    /// Center of the ambient glow, kept away from the edges. The original puts a set sun in the
    /// bottom corner, where most of the glow falls outside the window.
    var sun: UnitPoint {
        UnitPoint(x: min(max(state.sunX, 0.15), 0.85), y: min(state.sunY, 0.72))
    }

    func tints(_ opacity: Double) -> [Color] {
        state.triad.map { Self.color(Chronos.withLightness($0, in: 0.62...1, minChroma: 0.13)).opacity(opacity) }
    }

    var marks: [Color] {
        state.triad.map { Self.color(Chronos.withLightness($0, in: 0.72...1, minChroma: 0.11)) }
    }

    private static func color(_ c: Chronos.RGB) -> Color {
        Color(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}

/// Layer strengths. prismorphism's web values (12% ambient, 15% rim, 5% wash) are too faint
/// in a desktop window, so these are several times stronger.
enum PrismTokens {
    /// The three ambient glows: at the sun, beside it, and low in the middle.
    static let ambient = (0.55, 0.4, 0.2)
    static let shine = 1.0
    static let rim = 0.9
    /// The diagonal wash inside glass panels and the sidebar.
    static let wash = 0.08
    /// A selected segment or prominent pill.
    static let selectedWash = 0.38
    static let selectedRim = 1.0
}

private struct PrismKey: EnvironmentKey {
    static let defaultValue = PrismPalette()
}

/// Pins the sky to a moment instead of the clock, for snapshots.
private struct SkyTimeKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

extension EnvironmentValues {
    var prism: PrismPalette {
        get { self[PrismKey.self] }
        set { self[PrismKey.self] = newValue }
    }

    var skyTime: Date? {
        get { self[SkyTimeKey.self] }
        set { self[SkyTimeKey.self] = newValue }
    }
}

/// Puts the sky in the environment and updates it every minute, like the original.
struct ChronosSky<Content: View>: View {
    @Environment(\.skyTime) private var pinned
    @ViewBuilder var content: () -> Content

    var body: some View {
        TimelineView(.everyMinute) { context in
            content().environment(\.prism, .at(pinned ?? context.date))
        }
    }
}

/// The triad as a corner-to-corner gradient, the direction prismorphism's rims and washes use.
func prismDiagonal(_ colors: [Color]) -> LinearGradient {
    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// prismorphism's `pm-prismatic-shine`: a 1 pt triad line on the top edge, faded at the ends.
struct PrismShine: View {
    var inset: CGFloat = 0
    @Environment(\.prism) private var prism

    var body: some View {
        let t = prism.tints(PrismTokens.shine)
        LinearGradient(stops: [
            .init(color: t[0].opacity(0), location: 0.05),
            .init(color: t[0], location: 0.2),
            .init(color: t[1], location: 0.5),
            .init(color: t[2], location: 0.8),
            .init(color: t[2].opacity(0), location: 0.95),
        ], startPoint: .leading, endPoint: .trailing)
        .frame(height: 1)
        .padding(.horizontal, inset)
        .allowsHitTesting(false)
    }
}

/// prismorphism's `pm-prismatic`: the triad washed corner to corner across a glass surface.
struct PrismWash<S: Shape>: View {
    let shape: S
    var opacity = PrismTokens.wash
    @Environment(\.prism) private var prism

    var body: some View {
        shape.fill(prismDiagonal(prism.tints(opacity))).allowsHitTesting(false)
    }
}

/// prismorphism's `pm-prismatic-border-rounded`: a 1 pt triad rim, corner to corner.
struct PrismRim<S: InsettableShape>: View {
    let shape: S
    var opacity = PrismTokens.rim
    @Environment(\.prism) private var prism

    var body: some View {
        shape.strokeBorder(prismDiagonal(prism.tints(opacity)), lineWidth: 1)
            .allowsHitTesting(false)
    }
}

/// prismorphism's tinted-glass button, with the triad in place of the brand accent.
struct PrismSelection<S: InsettableShape>: View {
    let shape: S
    @Environment(\.prism) private var prism

    var body: some View {
        shape
            .fill(prismDiagonal(prism.marks.map { $0.opacity(PrismTokens.selectedWash) }))
            .overlay(shape.strokeBorder(prismDiagonal(prism.marks.map { $0.opacity(PrismTokens.selectedRim) }),
                                        lineWidth: 1))
    }
}
