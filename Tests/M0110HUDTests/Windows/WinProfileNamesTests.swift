import CM0110Win
import Foundation
import XCTest

@testable import M0110HUD

final class WinProfileNamesTests: XCTestCase {
    /// A name store backed by WinSettings, like the one WinApp uses.
    private final class Settings {
        var value = WinSettings()
        lazy var store = ProfileNameStore(
            load: { [unowned self] in
                let saved = value.profileNames ?? []
                return ProfileNameStore.State(
                    names: (0..<ProfileNames.count).map { saved.indices.contains($0) ? saved[$0] : "" },
                    pending: Dictionary(uniqueKeysWithValues: (value.profileNamesPending ?? [:])
                        .compactMap { key, name in Int(key).map { ($0, name) } }),
                    carriedOver: value.profileNamesCarriedOver ?? false)
            },
            store: { [unowned self] state in
                value.profileNames = state.names
                value.profileNamesPending = state.pending.isEmpty ? nil
                    : Dictionary(uniqueKeysWithValues: state.pending.map { (String($0.key), $0.value) })
                value.profileNamesCarriedOver = state.carriedOver
            })
    }

    func testThisPCsNameFits() {
        let name = DeviceName.current()
        XCTAssertTrue(name.hasPrefix("Windows"), name)
        XCTAssertTrue(name.hasSuffix("PC"), name)
        XCTAssertLessThanOrEqual(name.utf8.count, ProfileNamesWire.autoMaxBytes)
        XCTAssertGreaterThan(m0110_windows_build(), 0)
    }

    /// A settings.json from before the keyboard stored names.
    func testCarriesOverOldSettings() throws {
        let old = #"{ "profileNames": ["MacBook", "Windows PC"] }"#
        let settings = Settings()
        settings.value = try JSONDecoder().decode(WinSettings.self, from: Data(old.utf8))

        settings.store.carryOverIfNeeded(keyboard: ["MacBook Air M4", "", "", "", ""])
        XCTAssertEqual(settings.store.pending, [1: "Windows PC"])
        XCTAssertEqual(settings.value.profileNamesCarriedOver, true)

        XCTAssertEqual(
            ProfileNameSync.writes(keyboard: ["MacBook Air M4", "", "", "", ""],
                                   pending: settings.store.pending, own: 1, deviceName: "Windows 11 PC"),
            [ProfileNameSync.Write(op: .set, index: 1, name: "Windows PC")])

        settings.store.answered(ProfileNameSync.Write(op: .set, index: 1, name: "Windows PC"))
        settings.store.cache(["MacBook Air M4", "Windows PC", "", "", ""])
        XCTAssertNil(settings.value.profileNamesPending)
        XCTAssertEqual(settings.value.profileNames, ["MacBook Air M4", "Windows PC", "", "", ""])
        XCTAssertEqual(settings.value.profileName(0), "MacBook Air M4")
        XCTAssertEqual(settings.value.profileName(2), "Profile 3")
    }

    func testNamesItself() {
        XCTAssertEqual(
            ProfileNameSync.writes(keyboard: ["MacBook Air M4", "", "", "", ""],
                                   pending: [:], own: 1, deviceName: DeviceName.current()),
            [ProfileNameSync.Write(op: .auto, index: 1, name: DeviceName.current())])
    }

    func testPendingSurvivesSaving() throws {
        let settings = Settings()
        settings.store.edit(3, "Apple TV")
        let data = try JSONEncoder().encode(settings.value)
        let back = try JSONDecoder().decode(WinSettings.self, from: data)
        XCTAssertEqual(back.profileNamesPending, ["3": "Apple TV"])
        XCTAssertEqual(back.profileName(3), "Apple TV")
    }
}
