import XCTest

@testable import M0110HUD

/// Expected values come from prismorphism's js/chronos.mjs, run with
/// TZ=America/New_York at the same times.
final class ChronosTests: XCTestCase {
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let nyc = Chronos.Coordinates(lat: 40.71, lng: -74.0)

    private func local(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = newYork
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func rgb(_ r: Int, _ g: Int, _ b: Int) -> Chronos.RGB { .init(r: r, g: g, b: b) }

    /// Each channel may be off by one, since Swift and JS round at slightly different points.
    private func assertTriad(_ got: [Chronos.RGB], _ want: [Chronos.RGB],
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.count, 3, file: file, line: line)
        for (g, w) in zip(got, want) {
            XCTAssertLessThanOrEqual(abs(g.r - w.r), 1, "\(g) vs \(w)", file: file, line: line)
            XCTAssertLessThanOrEqual(abs(g.g - w.g), 1, "\(g) vs \(w)", file: file, line: line)
            XCTAssertLessThanOrEqual(abs(g.b - w.b), 1, "\(g) vs \(w)", file: file, line: line)
        }
    }

    private func state(_ date: Date, _ coords: Chronos.Coordinates? = nil) -> Chronos.State {
        Chronos.state(at: date, coordinates: coords ?? nyc, in: newYork)
    }

    func testSunPositionMatchesNOAA() {
        let sun = Chronos.sunPosition(at: local(2026, 6, 21, 13, 0), nyc, in: newYork)
        XCTAssertEqual(sun.elevation, 72.733, accuracy: 0.01)
        XCTAssertEqual(sun.azimuth, 182.058, accuracy: 0.01)

        let night = Chronos.sunPosition(at: local(2026, 12, 21, 2, 0), nyc, in: newYork)
        XCTAssertEqual(night.elevation, -58.398, accuracy: 0.01)
        XCTAssertEqual(night.azimuth, 66.543, accuracy: 0.01)
    }

    func testHighSunIsTheNoonPrism() {
        let s = state(local(2026, 6, 21, 13, 0))
        XCTAssertEqual(s.phase, .day)
        XCTAssertEqual(s.triad, [rgb(255, 30, 140), rgb(26, 229, 229), rgb(255, 232, 59)])
        XCTAssertEqual(s.glowCap, 0.9, accuracy: 0.001)
        XCTAssertEqual(s.triad, Chronos.noon.triad)
    }

    func testDeepNightIsTheLowestStop() {
        let s = state(local(2026, 12, 21, 2, 0))
        XCTAssertEqual(s.phase, .night)
        XCTAssertEqual(s.triad, [rgb(26, 35, 71), rgb(28, 62, 80), rgb(62, 46, 96)])
        XCTAssertEqual(s.glowCap, 0.35, accuracy: 0.001)
    }

    func testDawnMixesTheRisingRamp() {
        let s = state(local(2026, 6, 21, 5, 40))
        XCTAssertEqual(s.phase, .dawn)
        XCTAssertEqual(s.elevation, 1.691, accuracy: 0.01)
        assertTriad(s.triad, [rgb(247, 143, 139), rgb(138, 176, 227), rgb(255, 208, 149)])
        XCTAssertEqual(s.glowCap, 0.712, accuracy: 0.001)
    }

    func testMorningAboveTenDegreesIsDay() {
        let s = state(local(2026, 6, 21, 7, 0))
        XCTAssertEqual(s.phase, .day)
        assertTriad(s.triad, [rgb(255, 117, 173), rgb(78, 206, 228), rgb(255, 225, 147)])
        XCTAssertEqual(s.glowCap, 0.843, accuracy: 0.001)
    }

    func testEveningMixesTheSettingRamp() {
        let golden = state(local(2026, 6, 21, 20, 20))
        XCTAssertEqual(golden.phase, .golden)
        assertTriad(golden.triad, [rgb(253, 90, 63), rgb(255, 96, 138), rgb(119, 80, 179)])
        XCTAssertEqual(golden.glowCap, 0.807, accuracy: 0.001)

        let dusk = state(local(2026, 6, 21, 21, 10))
        XCTAssertEqual(dusk.phase, .night)
        assertTriad(dusk.triad, [rgb(60, 74, 141), rgb(77, 100, 160), rgb(179, 99, 129)])
        XCTAssertEqual(dusk.glowCap, 0.482, accuracy: 0.001)
    }

    func testGuessedLongitudeFollowsTheClockOffset() {
        // Eastern daylight time, four hours behind UTC.
        let summer = Chronos.guess(newYork, at: local(2026, 7, 1, 12, 0))
        XCTAssertEqual(summer, Chronos.Coordinates(lat: 40, lng: -60))
        let winter = Chronos.guess(newYork, at: local(2026, 1, 1, 12, 0))
        XCTAssertEqual(winter, Chronos.Coordinates(lat: 40, lng: -75))

        let s = state(local(2026, 3, 20, 7, 30), Chronos.Coordinates(lat: 40, lng: -60))
        XCTAssertEqual(s.phase, .day)
        assertTriad(s.triad, [rgb(255, 118, 174), rgb(79, 206, 228), rgb(255, 225, 147)])
    }

    func testSunSitsWhereTheOriginalPutsIt() {
        let noon = state(local(2026, 6, 21, 13, 0))
        XCTAssertEqual(noon.sunX, 0.511, accuracy: 0.001)
        XCTAssertEqual(noon.sunY, 0.221, accuracy: 0.001)
        let dawn = state(local(2026, 6, 21, 5, 40))
        XCTAssertEqual(dawn.sunX, 0, accuracy: 0.001)
        XCTAssertEqual(dawn.sunY, 0.884, accuracy: 0.001)
        // After sunset it stays at the trailing edge and the bottom, however low it goes.
        let dusk = state(local(2026, 6, 21, 21, 10))
        XCTAssertEqual(dusk.sunX, 1, accuracy: 0.001)
        XCTAssertEqual(dusk.sunY, 0.9, accuracy: 0.001)
    }

    func testLiftingLightnessKeepsHueAndClearsTheFloor() {
        let navy = rgb(26, 35, 71)
        let lifted = Chronos.withLightness(navy, in: 0.72...1)
        XCTAssertGreaterThan(lifted.r + lifted.g + lifted.b, 3 * 150, "\(lifted)")
        XCTAssertGreaterThan(lifted.b, lifted.r, "still blue: \(lifted)")
        let pink = rgb(255, 30, 140)
        XCTAssertEqual(Chronos.withLightness(pink, in: 0...1), pink)
        XCTAssertEqual(Chronos.withLightness(pink, in: 0...1, minChroma: 0.1), pink)
    }

    func testChromaFloorSaturatesWithoutTurningTheHue() {
        let teal = rgb(28, 62, 80)
        let vivid = Chronos.withLightness(teal, in: 0.62...1, minChroma: 0.13)
        let lifted = Chronos.withLightness(teal, in: 0.62...1)
        let spread = { (c: Chronos.RGB) in max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }
        XCTAssertGreaterThan(spread(vivid), spread(lifted), "\(vivid) vs \(lifted)")
        XCTAssertLessThan(vivid.r, vivid.g, "still teal: \(vivid)")
        XCTAssertLessThan(vivid.r, vivid.b, "still teal: \(vivid)")
    }

    func testMixEndsOnItsInputs() {
        let a = rgb(255, 30, 140), b = rgb(26, 229, 229)
        assertTriad([Chronos.mix(a, b, 0), Chronos.mix(a, b, 1), Chronos.mix(a, a, 0.5)], [a, b, a])
    }

    /// Grey has no hue, so mixing toward a color keeps that color's hue.
    func testMixFromGreyKeepsTheColoursHue() {
        let m = Chronos.mix(rgb(128, 128, 128), rgb(255, 0, 0), 0.5)
        XCTAssertGreaterThan(m.r, m.g)
        XCTAssertGreaterThan(m.r, m.b)
    }
}
