import XCTest

@testable import M0110HUD

final class ProfileNameSyncTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "com.shaedil.m0110hud.tests.profileNames"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: - Wire

    func testParsesWhatTheKeyboardSends() {
        let data = Data([1, 3, 4] + Array("Desk".utf8) + [0, 5] + Array("Caf\u{e9}".utf8))
        XCTAssertEqual(ProfileNamesWire.parse(data), ["Desk", "", "Café"])
    }

    /// After the names, a bit per profile whose name the keyboard read from
    /// the device itself; firmware from before it sends no such byte.
    func testReadsWhichNamesCameFromTheDevice() {
        let names: [UInt8] = [1, 3, 4] + Array("Desk".utf8) + [0, 2] + Array("S9".utf8)
        XCTAssertEqual(ProfileNamesWire.fromDevice(Data(names + [0b100])), [2])
        XCTAssertEqual(ProfileNamesWire.parse(Data(names + [0b100])), ["Desk", "", "S9"])
        XCTAssertEqual(ProfileNamesWire.fromDevice(Data(names)), [])
        XCTAssertEqual(ProfileNamesWire.fromDevice(Data(names + [0b1000_0000])), [],
                       "no such profile")
        XCTAssertEqual(ProfileNamesWire.fromDevice(Data([1, 1, 5, 65])), [], "malformed")
    }

    func testRejectsMalformedNames() {
        XCTAssertNil(ProfileNamesWire.parse(Data()))
        XCTAssertNil(ProfileNamesWire.parse(Data([2, 0])), "unknown format")
        XCTAssertNil(ProfileNamesWire.parse(Data([1, 2, 0])), "fewer names than counted")
        XCTAssertNil(ProfileNamesWire.parse(Data([1, 1, 5, 65])), "name runs past the end")
    }

    func testWriteFrames() {
        XCTAssertEqual(ProfileNamesWire.write(.set, index: 2, name: "PC"), Data([1, 2, 0x50, 0x43]))
        XCTAssertEqual(ProfileNamesWire.write(.auto, index: 0, name: ""), Data([2, 0]))
    }

    /// Names are cut to what the keyboard keeps, never inside a character.
    func testCleanFitsTheKeyboard() {
        XCTAssertEqual(ProfileNamesWire.clean("  Desk\t\n "), "Desk")
        XCTAssertEqual(ProfileNamesWire.clean(String(repeating: "a", count: 30)),
                       String(repeating: "a", count: 24))
        let accents = String(repeating: "é", count: 13) // 26 bytes
        XCTAssertEqual(ProfileNamesWire.clean(accents), String(repeating: "é", count: 12))
        XCTAssertEqual(ProfileNamesWire.clean("MacBook Pro M4 Max Extra", maxBytes: 21),
                       "MacBook Pro M4 Max Ex")
        let frame = ProfileNamesWire.write(.auto, index: 1, name: String(repeating: "x", count: 40))
        XCTAssertEqual(frame.count, 2 + ProfileNamesWire.autoMaxBytes)
    }

    func testNamesGenerationIsTheThirdByte() {
        XCTAssertNil(BluetoothMonitor.parseNamesGeneration(Data([0, 1])))
        XCTAssertEqual(BluetoothMonitor.parseNamesGeneration(Data([0, 1, 7])), 7)
        XCTAssertEqual(BluetoothMonitor.parseNamesGeneration(Data([9, 0, 1, 7]).dropFirst()), 7)
    }

    // MARK: - What to write

    private func write(_ op: ProfileNamesWire.Op, _ index: Int, _ name: String)
        -> ProfileNameSync.Write {
        ProfileNameSync.Write(op: op, index: index, name: name)
    }

    func testNamesItsOwnProfileWhenBlank() {
        XCTAssertEqual(
            ProfileNameSync.writes(keyboard: ["", "", ""], pending: [:], own: 1,
                                   deviceName: "MacBook Air M4"),
            [write(.auto, 1, "MacBook Air M4")])
    }

    /// A profile called "Profile N" is as good as unnamed.
    func testReplacesThePlaceholder() {
        XCTAssertEqual(
            ProfileNameSync.writes(keyboard: ["", "Profile 2"], pending: [:], own: 1,
                                   deviceName: "Windows 11 PC"),
            [write(.set, 1, ""), write(.auto, 1, "Windows 11 PC")])
        XCTAssertEqual(
            ProfileNameSync.writes(keyboard: ["Profile 2"], pending: [:], own: 0,
                                   deviceName: "Windows 11 PC"),
            [], "another profile's placeholder is a real name here")
    }

    func testLeavesANamedProfileAlone() {
        XCTAssertEqual(
            ProfileNameSync.writes(keyboard: ["Work", ""], pending: [:], own: 0,
                                   deviceName: "MacBook Air M4"),
            [])
    }

    /// Without knowing which profile is this computer it names nothing.
    func testNoOwnProfileNoName() {
        XCTAssertEqual(
            ProfileNameSync.writes(keyboard: ["", ""], pending: [:], own: nil,
                                   deviceName: "MacBook Air M4"),
            [])
        XCTAssertEqual(
            ProfileNameSync.writes(keyboard: ["", ""], pending: [:], own: 4,
                                   deviceName: "MacBook Air M4"),
            [], "a profile the keyboard does not have")
    }

    /// A computer that is not one of the keyboard's profiles cannot name
    /// anything, so its renames wait rather than being refused.
    func testNothingSentUntilOwnProfileKnown() {
        XCTAssertEqual(
            ProfileNameSync.writes(keyboard: ["", ""], pending: [1: "TV"], own: nil,
                                   deviceName: "MacBook Air M4"),
            [])
    }

    func testSendsRenamesMadeHere() {
        XCTAssertEqual(
            ProfileNameSync.writes(keyboard: ["Old", "Same", ""],
                                   pending: [0: "New", 1: "Same", 2: " TV "], own: 0,
                                   deviceName: "MacBook Air M4"),
            [write(.set, 0, "New"), write(.set, 2, "TV")])
    }

    /// Clearing this computer's name hands it back its own.
    func testClearingOwnNameRenamesIt() {
        XCTAssertEqual(
            ProfileNameSync.writes(keyboard: ["Work"], pending: [0: ""], own: 0,
                                   deviceName: "Windows 11 PC"),
            [write(.set, 0, ""), write(.auto, 0, "Windows 11 PC")])
    }

    /// The keyboard named this computer after itself before this app did:
    /// that is a stand-in, which this computer's own name replaces.
    func testReplacesTheDevicesOwnName() {
        XCTAssertEqual(
            ProfileNameSync.writes(keyboard: ["Galaxy S9", "DESKTOP-7F3K2"], pending: [:], own: 1,
                                   deviceName: "Windows 11 PC", fromDevice: [0, 1]),
            [write(.auto, 1, "Windows 11 PC")])
        XCTAssertEqual(
            ProfileNameSync.writes(keyboard: ["Galaxy S9", "Desk"], pending: [:], own: 1,
                                   deviceName: "Windows 11 PC", fromDevice: [0]),
            [], "the phone's is left to the phone")
    }

    /// A rename made here wins, even one that reads the same as the device's.
    func testRenameHereBeatsTheDevicesName() {
        XCTAssertEqual(
            ProfileNameSync.writes(keyboard: ["DESKTOP-7F3K2"], pending: [0: "DESKTOP-7F3K2"],
                                   own: 0, deviceName: "Windows 11 PC", fromDevice: [0]),
            [write(.set, 0, "DESKTOP-7F3K2")])
        XCTAssertEqual(
            ProfileNameSync.writes(keyboard: ["", "Galaxy S9"], pending: [1: "Sam's phone"],
                                   own: 0, deviceName: "MacBook Air M4", fromDevice: [1]),
            [write(.set, 1, "Sam's phone"), write(.auto, 0, "MacBook Air M4")])
    }

    func testCarriesOverOnlyRealNamesForBlankProfiles() {
        XCTAssertEqual(
            ProfileNameSync.carryOver(keyboard: ["", "Kept", "", ""],
                                      local: ["Home iMac", "Other", "Profile 3", "  "]),
            [0: "Home iMac"])
    }

    // MARK: - The copy here

    func testStoreCachesTheKeyboardsNames() {
        let store = ProfileNameStore(defaults: defaults)
        defaults.set("Stale", forKey: ProfileNames.key(1))
        store.cache(["Desk", ""])
        XCTAssertEqual(store.local(count: 2), ["Desk", ""])
        XCTAssertEqual(ProfileNames.name(for: 1, in: defaults), "Profile 2")
    }

    /// A rename on its way to the keyboard is not undone by an older read.
    func testStoreKeepsARenameUntilAnswered() {
        let store = ProfileNameStore(defaults: defaults)
        store.edit(0, "Studio")
        store.cache(["Old"])
        XCTAssertEqual(store.local(count: 1), ["Studio"])
        XCTAssertEqual(store.pending, [0: "Studio"])

        store.answered(write(.set, 0, "Studio"))
        XCTAssertEqual(store.pending, [:])
        store.cache(["Studio"])
        XCTAssertEqual(store.local(count: 1), ["Studio"])
    }

    /// A rename to what the keyboard already has is never sent, so it is
    /// settled by the read instead of waiting forever.
    func testStoreSettlesARenameTheKeyboardHas() {
        let store = ProfileNameStore(defaults: defaults)
        store.edit(0, " Desk ")
        store.cache(["Desk", "Other"])
        XCTAssertEqual(store.pending, [:])
        XCTAssertEqual(store.local(count: 2), ["Desk", "Other"])

        store.cache(["Renamed elsewhere", "Other"])
        XCTAssertEqual(store.local(count: 1), ["Renamed elsewhere"])
    }

    /// An answer to an earlier rename does not drop a later one.
    func testStoreKeepsANewerRename() {
        let store = ProfileNameStore(defaults: defaults)
        store.edit(0, "Stu")
        store.edit(0, "Studio")
        store.answered(write(.set, 0, "Stu"))
        XCTAssertEqual(store.pending, [0: "Studio"])
    }

    func testStoreCarriesOverOnce() {
        let store = ProfileNameStore(defaults: defaults)
        defaults.set("Home iMac", forKey: ProfileNames.key(0))
        defaults.set("Gaming PC", forKey: ProfileNames.key(1))

        store.carryOverIfNeeded(keyboard: ["", "Windows 11 PC", "", "", ""])
        XCTAssertEqual(store.pending, [0: "Home iMac"])
        store.answered(write(.set, 0, "Home iMac"))

        defaults.set("Later", forKey: ProfileNames.key(2))
        store.carryOverIfNeeded(keyboard: ["Home iMac", "Windows 11 PC", "", "", ""])
        XCTAssertEqual(store.pending, [:])
    }

    // MARK: - What a computer calls itself

    func testMacNames() {
        XCTAssertEqual(DeviceName.mac(productName: "MacBook Air (13-inch, M4, 2025)",
                                      modelIdentifier: "Mac16,12", cpuBrand: "Apple M4"),
                       "MacBook Air M4")
        XCTAssertEqual(DeviceName.mac(productName: "MacBook Pro (14-inch, M4 Pro, 2024)",
                                      modelIdentifier: "Mac16,8", cpuBrand: "Apple M4 Pro"),
                       "MacBook Pro M4")
        XCTAssertEqual(DeviceName.mac(productName: "Mac mini (2024)",
                                      modelIdentifier: "Mac16,10", cpuBrand: "Apple M4"),
                       "Mac mini M4")
        XCTAssertEqual(DeviceName.mac(productName: nil, modelIdentifier: "MacBookPro16,1",
                                      cpuBrand: "Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz"),
                       "MacBook Pro Intel")
        XCTAssertEqual(DeviceName.mac(productName: nil, modelIdentifier: "Mac14,13",
                                      cpuBrand: "Apple M2 Max"),
                       "Mac M2")
    }

    func testWindowsNames() {
        XCTAssertEqual(DeviceName.windows(build: 26100), "Windows 11 PC")
        XCTAssertEqual(DeviceName.windows(build: 22000), "Windows 11 PC")
        XCTAssertEqual(DeviceName.windows(build: 19045), "Windows 10 PC")
    }

    /// This Mac's name fits the keyboard with room for a number.
    func testThisMacsNameFits() {
        let name = DeviceName.current()
        XCTAssertFalse(name.isEmpty)
        XCTAssertLessThanOrEqual(name.utf8.count, ProfileNamesWire.autoMaxBytes)
    }
}
