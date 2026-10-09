import SwiftUI

/// The prismatic triad of one moment, as the window draws it: prismorphism's
/// colour layer, driven by `Chronos`.
///
/// Two ways to use it. `tints` are for glows, rims, shines and washes;
/// `marks` for the few things that carry a value: a slider's fill, a switch
/// that is on, the page stripes. Both keep the sky's hues but not its
/// darkness. The original lets night's triad sink to navy, which on a
/// near-black window is no colour at all, so tints are held to a middle
/// lightness and marks to a light one, both with a floor of saturation:
/// night comes out indigo, teal and violet rather than grey.
struct PrismPalette: Equatable {
    var state: Chronos.State

    init(_ state: Chronos.State = Chronos.noon) { self.state = state }

    /// The sky over the user's time zone at a moment.
    static func at(_ date: Date) -> PrismPalette { PrismPalette(Chronos.state(at: date)) }

    /// 0...1, low at night.
    var glowCap: Double { state.glowCap }

    /// What glows are multiplied by. The original scales them by the glow
    /// cap outright, which leaves a third of the glow at night; this keeps
    /// night calmer than day but still visibly prismatic.
    var glowScale: Double { 0.6 + 0.4 * glowCap }

    /// Where the ambient glow centres. The original parks a set sun on the
    /// bottom corner, where most of its glow falls outside the window; held
    /// in from the edges, the night glow stays on screen.
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

/// How strongly each prismatic layer draws.
///
/// prismorphism's own tokens are for a web page: a 12% ambient, a 15% rim,
/// a 5% wash. In a desktop window at arm's length those read as nothing at
/// all, so everything here runs several times stronger.
enum PrismTokens {
    /// The three ambient glows: at the sun, beside it, and low in the middle.
    static let ambient = (0.55, 0.4, 0.2)
    static let shine = 1.0
    static let rim = 0.9
    /// The diagonal triad wash inside glass panels and the sidebar.
    static let wash = 0.08
    /// A selected segment or prominent pill: a triad wash under a triad rim.
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

/// Puts the sky into the environment and keeps it current. A minute is the
/// original's own cadence, and the colour barely moves in one.
struct ChronosSky<Content: View>: View {
    @Environment(\.skyTime) private var pinned
    @ViewBuilder var content: () -> Content

    var body: some View {
        TimelineView(.everyMinute) { context in
            content().environment(\.prism, .at(pinned ?? context.date))
        }
    }
}

/// The triad as a gradient corner to corner, the direction prismorphism's
/// rims and washes run.
func prismDiagonal(_ colors: [Color]) -> LinearGradient {
    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// prismorphism's `pm-prismatic-shine`: a hairline of the triad along a
/// surface's top edge, fading out before either end, where the corners curve
/// away under it.
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

/// prismorphism's `pm-prismatic`: the triad washed corner to corner across a
/// glass surface.
struct PrismWash<S: Shape>: View {
    let shape: S
    var opacity = PrismTokens.wash
    @Environment(\.prism) private var prism

    var body: some View {
        shape.fill(prismDiagonal(prism.tints(opacity))).allowsHitTesting(false)
    }
}

/// prismorphism's `pm-prismatic-border-rounded`: a one-point rim running
/// through the triad corner to corner.
struct PrismRim<S: InsettableShape>: View {
    let shape: S
    var opacity = PrismTokens.rim
    @Environment(\.prism) private var prism

    var body: some View {
        shape.strokeBorder(prismDiagonal(prism.tints(opacity)), lineWidth: 1)
            .allowsHitTesting(false)
    }
}

/// A selected or prominent control: a faint triad wash inside a triad rim,
/// prismorphism's tinted-glass button with the triad standing in for the
/// brand accent.
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
