import Foundation

/// Port of prismorphism's Chronos engine (js/chronos.mjs): the sun's real position and the
/// three-color palette for it. Only the parts the window uses are ported. The triad, glow
/// cap and sun position match the original to within rounding.
enum Chronos {
    struct RGB: Equatable {
        var r, g, b: Int
    }

    /// Coarse time of day, the original's `data-tod`.
    enum Phase: String {
        case dawn, day, golden, night
    }

    struct Coordinates: Equatable {
        var lat: Double
        var lng: Double
    }

    struct State: Equatable {
        /// Warm to cool, like the original's `--chronos-1/2/3`.
        var triad: [RGB]
        /// 0...1. Glow is scaled by this so it fades at night.
        var glowCap: Double
        var phase: Phase
        var elevation: Double
        var azimuth: Double
        /// Sun position in a window, 0...1 from the leading and top edges (east to west, high
        /// to low). The glow is centered here.
        var sunX: Double
        var sunY: Double
    }

    /// The palette for a high sun, also used when there is no clock to follow.
    static let noon = State(triad: [RGB(r: 255, g: 30, b: 140),
                                    RGB(r: 26, g: 229, b: 229),
                                    RGB(r: 255, g: 232, b: 59)],
                            glowCap: 0.9, phase: .day, elevation: 90, azimuth: 180,
                            sunX: 0.5, sunY: 0.08)

    /// Guesses longitude from the UTC offset at latitude 40, like the original's `tzGuess`, so no
    /// location permission is needed. During daylight saving the guess is 15 degrees east, and
    /// `sunPosition` subtracts the same hour, so solar time still matches the wall clock.
    static func guess(_ timeZone: TimeZone, at date: Date) -> Coordinates {
        let hours = Double(timeZone.secondsFromGMT(for: date)) / 3600
        return Coordinates(lat: 40, lng: (hours * 15).rounded())
    }

    static func state(at date: Date, coordinates: Coordinates? = nil,
                      in timeZone: TimeZone = .current) -> State {
        let coords = coordinates ?? guess(timeZone, at: date)
        let sun = sunPosition(at: date, coords, in: timeZone)
        let rising = sun.azimuth < 180
        let stop = sample(rising ? rise : set, at: sun.elevation)

        let phase: Phase
        if sun.elevation > 10 { phase = .day }
        else if sun.elevation <= -6 { phase = .night }
        else { phase = rising ? .dawn : .golden }

        return State(triad: [stop.p1, stop.p2, stop.p3], glowCap: stop.glow,
                     phase: phase, elevation: sun.elevation, azimuth: sun.azimuth,
                     sunX: min(1, max(0, (sun.azimuth - 90) / 180)),
                     sunY: min(0.95, max(0.04, 0.9 - max(0, sun.elevation) / 90 * 0.84)))
    }

    // MARK: Solar position

    private static let rad = Double.pi / 180

    /// NOAA solar position: elevation and azimuth (clockwise from north), in degrees.
    static func sunPosition(at date: Date, _ coords: Coordinates,
                            in timeZone: TimeZone) -> (elevation: Double, azimuth: Double) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let dayOfYear = Double(cal.ordinality(of: .day, in: .year, for: date) ?? 1)
        let t = cal.dateComponents([.hour, .minute, .second], from: date)
        let hours = Double(t.hour ?? 0) + Double(t.minute ?? 0) / 60 + Double(t.second ?? 0) / 3600
        let gamma = (2 * Double.pi / 365) * (dayOfYear - 1 + (hours - 12) / 24)

        let eqtime = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
            - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let decl = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)

        let tzOffset = Double(timeZone.secondsFromGMT(for: date)) / 3600
        let tst = hours * 60 + (eqtime + 4 * coords.lng - 60 * tzOffset)
        let ha = (tst / 4 - 180) * rad
        let lat = coords.lat * rad

        let cosZ = sin(lat) * sin(decl) + cos(lat) * cos(decl) * cos(ha)
        let elevation = 90 - acos(min(1, max(-1, cosZ))) / rad
        let az = atan2(sin(ha), cos(ha) * sin(lat) - tan(decl) * cos(lat))
        let azimuth = (az / rad + 180).truncatingRemainder(dividingBy: 360)
        return (elevation, azimuth)
    }

    // MARK: Sky ramps

    /// One stop of a ramp, keyed by the sun's altitude in degrees.
    struct Stop {
        var el: Double
        var p1, p2, p3: RGB
        var glow: Double
    }

    private static func stop(_ el: Double, _ p1: [Int], _ p2: [Int], _ p3: [Int], _ glow: Double) -> Stop {
        Stop(el: el,
             p1: RGB(r: p1[0], g: p1[1], b: p1[2]),
             p2: RGB(r: p2[0], g: p2[1], b: p2[2]),
             p3: RGB(r: p3[0], g: p3[1], b: p3[2]),
             glow: glow)
    }

    /// The original's DEFAULT_RISE, from deep night up.
    static let rise: [Stop] = [
        stop(-14, [26, 35, 71], [28, 62, 80], [62, 46, 96], 0.35),
        stop(-7, [44, 74, 124], [46, 107, 125], [176, 120, 158], 0.50),
        stop(-2, [224, 138, 170], [138, 160, 224], [255, 200, 150], 0.65),
        stop(4, [255, 150, 115], [140, 185, 228], [255, 214, 150], 0.75),
        stop(14, [255, 120, 175], [80, 205, 228], [255, 225, 150], 0.84),
        stop(45, [255, 30, 140], [26, 229, 229], [255, 232, 59], 0.90),
    ]

    /// The original's DEFAULT_SET, from high sun down.
    static let set: [Stop] = [
        stop(45, [255, 30, 140], [26, 229, 229], [255, 232, 59], 0.90),
        stop(14, [255, 160, 90], [255, 210, 140], [130, 165, 205], 0.88),
        stop(5, [255, 124, 63], [255, 176, 100], [120, 150, 200], 0.86),
        stop(1, [255, 92, 57], [255, 94, 140], [120, 80, 180], 0.82),
        stop(-2, [212, 71, 126], [255, 128, 108], [96, 80, 168], 0.60),
        stop(-7, [58, 74, 140], [74, 100, 158], [180, 100, 128], 0.48),
        stop(-14, [26, 35, 71], [28, 62, 80], [62, 46, 96], 0.35),
    ]

    /// Mixes the two stops around `el`, clamping to the end stops outside the range.
    static func sample(_ stops: [Stop], at el: Double) -> Stop {
        let asc = stops[0].el < stops[stops.count - 1].el ? stops : stops.reversed()
        guard let first = asc.first, let last = asc.last else { return set[0] }
        if el <= first.el { return first }
        if el >= last.el { return last }
        for (a, b) in zip(asc, asc.dropFirst()) where el >= a.el && el <= b.el {
            let t = (el - a.el) / (b.el - a.el)
            return Stop(el: el,
                        p1: mix(a.p1, b.p1, t), p2: mix(a.p2, b.p2, t), p3: mix(a.p3, b.p3, t),
                        glow: a.glow + (b.glow - a.glow) * t)
        }
        return last
    }

    // MARK: OKLCH

    /// Mixes in OKLCH so a transition stays bright with no muddy midpoint. Hue takes the short
    /// way around, and a near-gray end uses the other end's hue.
    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        let A = lab(a), B = lab(b)
        let ca = hypot(A.a, A.b), cb = hypot(B.a, B.b)
        let ha = atan2(A.b, A.a), hb = atan2(B.b, B.a)
        let L = A.L + (B.L - A.L) * t
        let C = ca + (cb - ca) * t
        let h = ca < 0.004 ? hb : (cb < 0.004 ? ha : lerpAngle(ha, hb, t))
        return rgb(L: L, a: C * cos(h), b: C * sin(h))
    }

    /// Same hue with lightness clamped to `range` and chroma at least `minChroma`, so night's
    /// navy still shows on a dark window. Grays only change lightness.
    static func withLightness(_ c: RGB, in range: ClosedRange<Double>, minChroma: Double = 0) -> RGB {
        let x = lab(c)
        let L = min(max(x.L, range.lowerBound), range.upperBound)
        let chroma = hypot(x.a, x.b)
        let boost = chroma > 0.004 && chroma < minChroma ? minChroma / chroma : 1
        guard L != x.L || boost != 1 else { return c }
        return rgb(L: L, a: x.a * boost, b: x.b * boost)
    }

    private static func lerpAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var d = b - a
        while d > Double.pi { d -= 2 * Double.pi }
        while d < -Double.pi { d += 2 * Double.pi }
        return a + d * t
    }

    private static func linear(_ c: Int) -> Double {
        let v = Double(c) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ c: Double) -> Int {
        let v = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        return Int(max(0, min(255, (v * 255).rounded())))
    }

    private static func lab(_ c: RGB) -> (L: Double, a: Double, b: Double) {
        let lr = linear(c.r), lg = linear(c.g), lb = linear(c.b)
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    private static func rgb(L: Double, a: Double, b: Double) -> RGB {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        return RGB(r: encoded(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                   g: encoded(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                   b: encoded(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }
}
