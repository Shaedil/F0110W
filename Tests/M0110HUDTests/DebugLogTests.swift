import XCTest

@testable import M0110HUD

final class DebugLogTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugLogTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testKeepsOnlyTheNewestLines() {
        let log = DebugLog(file: nil, capacity: 3)
        for i in 1...5 { log.add(.bluetooth, "line \(i)") }
        XCTAssertEqual(log.snapshot().map(\.message), ["line 3", "line 4", "line 5"])
    }

    /// The clipboard puts its own name on its messages; the tag already says it.
    func testDropsTheSourcesOwnPrefix() {
        let log = DebugLog(file: nil)
        log.add(.clipboard, "clipboard: ready")
        log.add(.bluetooth, "clipboard: not this source's prefix")
        XCTAssertEqual(log.snapshot().map(\.message),
                       ["ready", "clipboard: not this source's prefix"])
    }

    func testWritesEachLineToTheFile() throws {
        let file = dir.appendingPathComponent("Logs/hud.log")
        let log = DebugLog(file: file)
        let date = Date(timeIntervalSince1970: 0)
        log.add(.app, "started", at: date)
        log.add(.bluetooth, "GATT link up", at: date)
        log.flush()

        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix(" [app] started"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix(" [bluetooth] GATT link up"), lines[1])
    }

    /// Past the cap the file is moved aside, replacing the last one moved, so
    /// the log never grows past two files.
    func testRotatesAtTheCap() throws {
        let file = dir.appendingPathComponent("hud.log")
        let log = DebugLog(file: file, maxFileBytes: 200)
        for i in 0..<20 { log.add(.bluetooth, "line \(i) " + String(repeating: "x", count: 40)) }
        log.flush()

        let current = try Data(contentsOf: file)
        let old = try Data(contentsOf: DebugLog.rotated(file))
        XCTAssertLessThanOrEqual(current.count, 200 + 100)
        XCTAssertLessThanOrEqual(old.count, 200 + 100)
        XCTAssertEqual(DebugLog.rotated(file).lastPathComponent, "hud.1.log")
        let last = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(last.contains("line 19 "))
    }

    /// The debug panel's made-up events stay out of the file.
    func testWritesNothingWhenNotPersisting() {
        let file = dir.appendingPathComponent("hud.log")
        let log = DebugLog(file: file)
        log.persists = false
        log.add(.app, "showing movedAway")
        log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(log.snapshot().count, 1)
    }

    func testClearEmptiesTheListOnly() throws {
        let file = dir.appendingPathComponent("hud.log")
        let log = DebugLog(file: file)
        log.add(.app, "kept in the file")
        log.clear()
        log.flush()
        XCTAssertTrue(log.snapshot().isEmpty)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("kept in the file"))
    }

    func testFilterAdmitsItsSourceOnly() {
        let entry = DebugLog.Entry(id: 0, date: Date(), source: .studio, message: "x")
        XCTAssertTrue(LogFilter.all.admits(entry))
        XCTAssertTrue(LogFilter.studio.admits(entry))
        XCTAssertFalse(LogFilter.bluetooth.admits(entry))
    }
}

final class ProfileMoveTests: XCTestCase {
    func testOutcomes() {
        XCTAssertEqual(ProfileMove(previous: nil, active: 1, own: 1).outcome, .firstReport)
        XCTAssertEqual(ProfileMove(previous: 1, active: 1, own: 1).outcome, .unchanged)
        XCTAssertEqual(ProfileMove(previous: 0, active: 1, own: nil).outcome, .ownUnknown)
        XCTAssertEqual(ProfileMove(previous: 0, active: 1, own: 0).outcome, .away)
        XCTAssertEqual(ProfileMove(previous: 1, active: 0, own: 0).outcome, .back)
        XCTAssertEqual(ProfileMove(previous: 1, active: 0, own: 2).outcome, .elsewhere)
    }

    /// The case seen live: the keyboard named this computer as a profile that
    /// was not the one it left, so leaving showed nothing. The log has to say so.
    func testExplainsASilentSwitchInSettingsNumbering() {
        XCTAssertEqual(ProfileMove(previous: 1, active: 0, own: 2).explanation,
                       "Profile 2 to Profile 1, neither is this computer (Profile 3); nothing shown")
        XCTAssertEqual(ProfileMove(previous: 2, active: 0, own: 2).explanation,
                       "Profile 3 to Profile 1, away from this computer (Profile 3); showing \"Moved to\"")
        XCTAssertEqual(ProfileMove(previous: nil, active: 1, own: 2).explanation,
                       "Profile 2 active, this computer is Profile 3; first report since connecting, nothing shown")
    }
}
