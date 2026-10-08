import XCTest

@testable import M0110HUD

final class PresenceTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func present(grace: TimeInterval = 3) -> Presence {
        var p = Presence(grace: grace)
        XCTAssertEqual(p.observe(present: true, at: at(0)), .arrived)
        return p
    }

    func testArrivesOnceAndStaysQuietWhilePresent() {
        var p = present()
        XCTAssertNil(p.observe(present: true, at: at(2)))
        XCTAssertNil(p.observe(present: true, at: at(4)))
        XCTAssertTrue(p.isPresent)
    }

    /// The case the old poll missed: a drop caught only by the app's own link,
    /// then still gone when the grace period ends.
    func testLinkDropThatLastsIsAnnounced() {
        var p = present()
        XCTAssertEqual(p.linkDropped(at: at(10)), .leaving(until: at(13)))
        XCTAssertTrue(p.isPresent, "still present until the grace period says otherwise")
        XCTAssertEqual(p.observe(present: false, at: at(13)), .left)
        XCTAssertFalse(p.isPresent)
    }

    /// Today's 0.7 s blips: gone and back inside the grace period says nothing,
    /// in either direction.
    func testBlipIsNotAnnounced() {
        var p = present()
        XCTAssertEqual(p.linkDropped(at: at(10)), .leaving(until: at(13)))
        XCTAssertNil(p.observe(present: true, at: at(10.7)))
        XCTAssertEqual(p.observe(present: true, at: at(13)), .stayed(missingFor: 3))
        XCTAssertTrue(p.isPresent)
        XCTAssertNil(p.observe(present: true, at: at(15)))
    }

    /// A poll inside the grace period that finds it missing does not decide
    /// early, and one that finds it back does not cancel: only the end counts.
    func testPollsInsideGraceDoNotDecide() {
        var p = present()
        XCTAssertEqual(p.observe(present: false, at: at(10)), .leaving(until: at(13)))
        XCTAssertNil(p.observe(present: false, at: at(11)))
        XCTAssertNil(p.observe(present: true, at: at(12)))
        XCTAssertEqual(p.observe(present: false, at: at(13.05)), .left)
    }

    /// A second signal during a grace period does not push its end back.
    func testSecondSignalDoesNotRestartGrace() {
        var p = present()
        XCTAssertEqual(p.observe(present: false, at: at(10)), .leaving(until: at(13)))
        XCTAssertNil(p.linkDropped(at: at(11)))
        XCTAssertEqual(p.observe(present: false, at: at(13)), .left)
    }

    func testReturnAfterLeavingArrivesAgain() {
        var p = present()
        _ = p.linkDropped(at: at(10))
        XCTAssertEqual(p.observe(present: false, at: at(13)), .left)
        XCTAssertNil(p.observe(present: false, at: at(20)))
        XCTAssertNil(p.linkDropped(at: at(21)), "nothing to lose while already gone")
        XCTAssertEqual(p.observe(present: true, at: at(30)), .arrived)
    }

    func testZeroGraceDecidesAtOnce() {
        var p = present(grace: 0)
        XCTAssertEqual(p.observe(present: false, at: at(10)), .leaving(until: at(10)))
        XCTAssertEqual(p.observe(present: false, at: at(10)), .left)
    }

    func testNegativeGraceIsZero() {
        XCTAssertEqual(Presence(grace: -1).grace, 0)
    }
}

final class ProfileReportTests: XCTestCase {
    func testParsesActiveAndOwn() throws {
        let report = try XCTUnwrap(BluetoothMonitor.parseProfileState(Data([1, 0])))
        XCTAssertEqual(report.active, 1)
        XCTAssertEqual(report.own, 0)
    }

    func testUnbondedIsNil() throws {
        let report = try XCTUnwrap(BluetoothMonitor.parseProfileState(Data([2, 0xFF])))
        XCTAssertEqual(report.active, 2)
        XCTAssertNil(report.own)
    }

    func testLaterFieldsAreIgnored() throws {
        let report = try XCTUnwrap(BluetoothMonitor.parseProfileState(Data([3, 3, 9, 9])))
        XCTAssertEqual(report.active, 3)
        XCTAssertEqual(report.own, 3)
    }

    func testShortValueIsRejected() {
        XCTAssertNil(BluetoothMonitor.parseProfileState(Data()))
        XCTAssertNil(BluetoothMonitor.parseProfileState(Data([1])))
    }

    /// Must match PROFILE_UUID in config/src/profile_report.c on the firmware
    /// branch.
    func testUUIDsMatchTheFirmware() {
        XCTAssertEqual(BluetoothMonitor.profileService.uuidString,
                       "05B3A8EB-1160-4B0F-B56D-700006AAEFEB")
        XCTAssertEqual(BluetoothMonitor.profileStateChar.uuidString,
                       "05B3A8EC-1160-4B0F-B56D-700006AAEFEB")
    }
}

final class DisconnectHoldTests: XCTestCase {
    private let dust = HUDStyle.defaults[.disconnected]!

    /// A disconnect stays up as long as a connect does.
    func testDisconnectHoldsForTheConfiguredTime() {
        XCTAssertEqual(HUDController.hold(for: dust, configured: 7), 7)
        XCTAssertEqual(HUDController.hold(for: HUDStyle.defaults[.connected]!, configured: 7), 7)
    }

    func testHoldIsNeverShorterThanTheCrumble() {
        XCTAssertEqual(HUDController.hold(for: dust, configured: 1), SpinningBoardView.dustEnds)
    }

    /// The crumble ends with the hold, so the fade and the last of the dust
    /// still finish together.
    func testCrumbleEndsWithTheHold() {
        let hold = HUDController.hold(for: dust, configured: 7)
        XCTAssertEqual(SpinningBoardView.dustBeat(hold: hold) + SpinningBoardView.dustDuration,
                       hold, accuracy: 1e-9)
        XCTAssertEqual(SpinningBoardView.dustBeat(hold: nil), SpinningBoardView.dustBeat)
        XCTAssertEqual(SpinningBoardView.dustBeat(hold: 1), SpinningBoardView.dustBeat)
    }
}
