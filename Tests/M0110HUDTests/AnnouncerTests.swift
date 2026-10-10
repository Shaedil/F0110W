import XCTest

@testable import M0110HUD

private final class Memory: AnnouncerMemory {
    var lowAlertArmed = true
    var lastMilestone: Int?
    var lastConnectAt: Date?
    var lastDisconnectAt: Date?
    var lastBattery: Int?
    var diedAnnounced = false
}

final class AnnouncerTests: XCTestCase {
    private let memory = Memory()
    private var config = Config()
    private lazy var announcer: Announcer = {
        let a = Announcer(config: config, memory: memory)
        a.profileName = { "P\($0)" }
        return a
    }()

    /// Noon on a fixed day, so hour offsets stay inside it.
    private let noon = Calendar.current.date(
        from: DateComponents(year: 2026, month: 10, day: 7, hour: 12))!
    private func at(hours: Double) -> Date { noon.addingTimeInterval(hours * 3600) }

    func testFirstConnectOfTheDayIsAnArrival() {
        XCTAssertEqual(announcer.connect(battery: 80, isInitial: false, now: at(hours: 0)),
                       Announcement(kind: .arrived, battery: 80))
        _ = announcer.disconnect(now: at(hours: 1))
        XCTAssertEqual(announcer.connect(battery: nil, isInitial: false, now: at(hours: 2))?.kind,
                       .connected)
        _ = announcer.disconnect(now: at(hours: 2.5))
        XCTAssertEqual(announcer.connect(battery: nil, isInitial: false, now: at(hours: 7))?.kind,
                       .arrived, "four hours away starts a new stretch")
    }

    func testAlreadyConnectedAtLaunchCanBeSilenced() {
        config.suppressInitial = true
        XCTAssertNil(announcer.connect(battery: 50, isInitial: true, now: at(hours: 0)))
        XCTAssertEqual(memory.lastConnectAt, at(hours: 0))
    }

    func testLeavingOnAnEmptyBatteryIsDyingOnce() {
        _ = announcer.battery(level: 2)
        XCTAssertEqual(announcer.disconnect(now: at(hours: 0)), Announcement(kind: .died, battery: 2))
        XCTAssertNil(announcer.disconnect(now: at(hours: 1)))
    }

    func testDisconnectsCanBeSilenced() {
        config.showDisconnect = false
        XCTAssertNil(announcer.disconnect(now: at(hours: 0)))
    }

    func testOnlyMovesInvolvingThisComputerAreAnnounced() {
        XCTAssertNil(announcer.profileSwitch(active: 0, own: 0), "the first report sets the scene")
        XCTAssertEqual(announcer.profileSwitch(active: 2, own: 0),
                       Announcement(kind: .movedAway, battery: nil, detail: "P2"))
        XCTAssertNil(announcer.profileSwitch(active: 3, own: 0), "between two other computers")
        XCTAssertEqual(announcer.profileSwitch(active: 0, own: 0)?.kind, .movedBack)
    }

    func testLowAlertFiresOncePerDescent() {
        XCTAssertEqual(announcer.battery(level: 20).map(\.kind), [.lowBattery, .lowBattery],
                       "the alert, then the 20% milestone in its place")
        XCTAssertEqual(announcer.battery(level: 20), [])
        _ = announcer.battery(level: 30)
        XCTAssertTrue(memory.lowAlertArmed)
    }

    func testMilestonesOnlyOnTheWayDown() {
        XCTAssertEqual(announcer.battery(level: 75), [Announcement(kind: .connected, battery: 75)])
        XCTAssertEqual(announcer.battery(level: 72), [])
        XCTAssertEqual(announcer.battery(level: 81), [], "recovering one step does not rearm")
        XCTAssertEqual(announcer.battery(level: 69).map(\.battery), [69])
    }

    func testAnEmptyReportIsDyingOnce() {
        XCTAssertEqual(announcer.battery(level: 0), [Announcement(kind: .died, battery: 0)])
        XCTAssertFalse(announcer.battery(level: 0).contains { $0.kind == .died })
        _ = announcer.battery(level: 6)
        XCTAssertFalse(memory.diedAnnounced)
    }
}
