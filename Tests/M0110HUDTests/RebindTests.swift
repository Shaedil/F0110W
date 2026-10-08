import XCTest

@testable import M0110HUD

// Behaviour table as the firmware reports it, by the display names in ZMK's
// behaviour .dtsi files. Ids are arbitrary but distinct.
private let keyPress = BehaviorInfo(id: 5, displayName: "Key Press", param1: .hidUsage)
private let transparent = BehaviorInfo(id: 9, displayName: "Transparent", param1: .none)
private let none = BehaviorInfo(id: 8, displayName: "None", param1: .none)
private let bluetooth = BehaviorInfo(id: 2, displayName: "Bluetooth", param1: .other)
private let table: [Int32: BehaviorInfo] = [5: keyPress, 9: transparent, 8: none, 2: bluetooth]

private let volumeUp = HIDKeycodes.encode(page: HIDKeycodes.consumerPage, usage: 0xE9)

final class RebindTests: XCTestCase {
    func testKeyPressKeepsItsBehaviourAndTakesTheNewKeycode() {
        let a = BehaviorBinding(behaviorID: 5, param1: HIDKeycodes.encode(usage: 0x04), param2: 0)
        XCTAssertEqual(a.sending(volumeUp, behaviors: table),
                       BehaviorBinding(behaviorID: 5, param1: volumeUp, param2: 0))
    }

    /// The Fn layer is mostly `&trans`. Those slots had no keycode to swap, so
    /// the picker refused them and only base-layer keys could be rebound.
    func testTransparentSlotBecomesAKeyPress() {
        let trans = BehaviorBinding(behaviorID: 9, param1: 0, param2: 0)
        XCTAssertEqual(trans.sending(volumeUp, behaviors: table),
                       BehaviorBinding(behaviorID: 5, param1: volumeUp, param2: 0))
    }

    func testNoneSlotBecomesAKeyPress() {
        let empty = BehaviorBinding(behaviorID: 8, param1: 0, param2: 0)
        XCTAssertEqual(empty.sending(volumeUp, behaviors: table)?.behaviorID, 5)
    }

    func testOtherBehavioursAreNotOverwritten() {
        let bt = BehaviorBinding(behaviorID: 2, param1: 3, param2: 0)
        XCTAssertNil(bt.sending(volumeUp, behaviors: table))
    }

    func testUnknownBehaviourIsNotOverwritten() {
        let unknown = BehaviorBinding(behaviorID: 77, param1: 0, param2: 0)
        XCTAssertNil(unknown.sending(volumeUp, behaviors: table))
    }

    func testTransparentStaysPutWithoutAKeyPressBehaviour() {
        let trans = BehaviorBinding(behaviorID: 9, param1: 0, param2: 0)
        XCTAssertNil(trans.sending(volumeUp, behaviors: [9: transparent, 2: bluetooth]))
    }

    /// ZMK's default BASIC consumer report refuses usages above 0xFF.
    func testMediaGroupIsConsumerPageWithinTheBasicReport() throws {
        let media = try XCTUnwrap(HIDKeycodes.groups.first { $0.0 == "Media" }?.1)
        XCTAssertTrue(media.contains(volumeUp))
        for param in media {
            let (page, usage) = HIDKeycodes.decode(param)
            XCTAssertEqual(page, HIDKeycodes.consumerPage)
            XCTAssertLessThanOrEqual(usage, 0xFF)
        }
    }

    func testKeyboardGroupsAreEncodedOnTheKeyboardPage() {
        for (name, params) in HIDKeycodes.groups where name != "Media" {
            for param in params {
                XCTAssertEqual(HIDKeycodes.decode(param).page, HIDKeycodes.keyboardPage, name)
            }
        }
    }
}
