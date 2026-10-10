import XCTest

@testable import M0110HUD

final class ProfileStateTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "com.shaedil.m0110hud.tests.profileState"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testTypingHereWhenActiveIsOwn() {
        XCTAssertEqual(ProfileState(active: 1, own: 1).typingHere, true)
        XCTAssertEqual(ProfileState(active: 2, own: 0).typingHere, false)
    }

    func testUnknownOwnSaysNothing() {
        let state = ProfileState(active: 0, own: nil)
        XCTAssertNil(state.typingHere)
        XCTAssertNil(state.summary(in: defaults))
    }

    func testSummaryHereNamesTheProfile() {
        XCTAssertEqual(ProfileState(active: 0, own: 0).summary(in: defaults),
                       "Typing to this Mac (Profile 1)")
        defaults.set("Home iMac", forKey: ProfileNames.key(0))
        XCTAssertEqual(ProfileState(active: 0, own: 0).summary(in: defaults),
                       "Typing to this Mac (Home iMac)")
    }

    /// An unnamed profile is not shown twice, as in "Profile 2 (Profile 2)".
    func testSummaryAwayAddsTheNumberOnlyToANamedProfile() {
        XCTAssertEqual(ProfileState(active: 1, own: 0).summary(in: defaults),
                       "Typing to Profile 2")
        defaults.set("Work Laptop", forKey: ProfileNames.key(1))
        XCTAssertEqual(ProfileState(active: 1, own: 0).summary(in: defaults),
                       "Typing to Work Laptop (Profile 2)")
        XCTAssertEqual(ProfileState(active: 1, own: 0).activeName(in: defaults), "Work Laptop")
    }
}
