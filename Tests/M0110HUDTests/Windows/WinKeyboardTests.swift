import Foundation
import XCTest

@testable import M0110HUD

// The Windows keymap editor against a scripted ZMK Studio firmware: what the
// window does with a real keyboard, without one. The firmware answers each
// request the way zmk-studio-messages describes, refuses keymap calls while
// locked, and keeps the edits it is sent.

/// A ZMK Studio endpoint in memory: a transport WinKeyboard's client talks to.
private final class FakeFirmware: StudioTransport {
    var label = "COM9"
    var isOpen = true
    var responseTimeout: TimeInterval = 0.5

    private let lock = NSLock()
    private var outgoing: [[UInt8]] = []
    private(set) var locked: Bool
    private(set) var layers: [KeymapLayer]
    private(set) var saves = 0
    private(set) var discards = 0
    let behaviors: [BehaviorInfo]

    init(locked: Bool, layers: [KeymapLayer], behaviors: [BehaviorInfo]) {
        self.locked = locked
        self.layers = layers
        self.behaviors = behaviors
    }

    func open() throws {}
    func close() {}

    /// Someone pressed &studio_unlock, or the idle timer ran out: the lock
    /// changes and the firmware says so.
    func setLocked(_ value: Bool) {
        lock.lock()
        locked = value
        var core = ProtobufWriter(); core.uint32(1, value ? 0 : 1, skipZero: false)
        var n = ProtobufWriter(); n.message(2, core.bytes)
        var w = ProtobufWriter(); w.message(2, n.bytes)
        outgoing.append(w.bytes)
        lock.unlock()
    }

    func binding(layer: Int, position: Int) -> BehaviorBinding {
        lock.lock(); defer { lock.unlock() }
        return layers[layer].bindings[position]
    }

    func receiveFrame(timeout: TimeInterval) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let frame = try receiveFrameIfAvailable() { return frame }
            Thread.sleep(forTimeInterval: 0.005)
        } while Date() < deadline
        throw StudioError.timeout("fake firmware frame")
    }

    func receiveFrameIfAvailable() throws -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        return outgoing.isEmpty ? nil : outgoing.removeFirst()
    }

    func send(_ payload: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        var r = ProtobufReader(payload)
        var id: UInt32 = 0
        var subsystem = 0
        var body: [UInt8] = []
        while !r.isAtEnd {
            let (field, type) = try r.nextField()
            if field == 1, type == .varint { id = UInt32(try r.varint()) }
            else if type == .lengthDelimited { subsystem = field; body = try r.bytesField() }
            else { try r.skip(type) }
        }
        let (call, argument) = try Self.call(in: body)
        let reply: [UInt8]
        switch (subsystem, call) {
        case (3, 1): // core.get_device_info
            var info = ProtobufWriter(); info.string(1, "M0110")
            var core = ProtobufWriter(); core.message(1, info.bytes)
            reply = Self.response(id, 3, core.bytes)
        case (3, 2): // core.get_lock_state
            var core = ProtobufWriter(); core.uint32(2, locked ? 0 : 1, skipZero: false)
            reply = Self.response(id, 3, core.bytes)
        case (4, _) where locked, (5, _) where locked:
            // meta.ErrorConditions{simple_error = 2 UNLOCK_REQUIRED}
            var meta = ProtobufWriter(); meta.uint32(2, 1, skipZero: false)
            reply = Self.response(id, 2, meta.bytes)
        case (4, 1): // behaviors.list_all_behaviors
            var list = ProtobufWriter()
            for b in behaviors { list.uint32(1, UInt32(b.id), skipZero: false) }
            var w = ProtobufWriter(); w.message(1, list.bytes)
            reply = Self.response(id, 4, w.bytes)
        case (4, 2): // behaviors.get_behavior_details
            var a = ProtobufReader(argument)
            var wanted: UInt32 = 0
            while !a.isAtEnd { let (f, t) = try a.nextField(); if f == 1 { wanted = UInt32(try a.varint()) } else { try a.skip(t) } }
            let info = behaviors.first { UInt32($0.id) == wanted }!
            var details = ProtobufWriter()
            details.uint32(1, UInt32(info.id), skipZero: false)
            details.string(2, info.displayName)
            // One parameter set: param1 a HID usage (5), a layer id (6) or nothing (2).
            var value = ProtobufWriter()
            switch info.param1 {
            case .hidUsage: value.message(5, [])
            case .layerID: value.message(6, [])
            case .none, .other: value.message(2, [])
            }
            var set = ProtobufWriter(); set.message(1, value.bytes)
            details.message(3, set.bytes)
            var w = ProtobufWriter(); w.message(2, details.bytes)
            reply = Self.response(id, 4, w.bytes)
        case (5, 1): // keymap.get_keymap
            var keymap = ProtobufWriter()
            for layer in layers {
                var l = ProtobufWriter()
                l.uint32(1, layer.id, skipZero: false)
                l.string(2, layer.name)
                for b in layer.bindings { l.message(3, b.encoded) }
                keymap.message(1, l.bytes)
            }
            keymap.uint32(2, 0, skipZero: false)
            keymap.uint32(3, 16)
            var w = ProtobufWriter(); w.message(1, keymap.bytes)
            reply = Self.response(id, 5, w.bytes)
        case (5, 2): // keymap.set_layer_binding
            var a = ProtobufReader(argument)
            var layerID: UInt32 = 0, position = 0
            var binding = BehaviorBinding(behaviorID: 0, param1: 0, param2: 0)
            while !a.isAtEnd {
                let (f, t) = try a.nextField()
                switch f {
                case 1: layerID = UInt32(try a.varint())
                case 2: position = Int(try a.varint())
                case 3: binding = try BehaviorBinding.decode(a.bytesField())
                default: try a.skip(t)
                }
            }
            let index = layers.firstIndex { $0.id == layerID }!
            layers[index].bindings[position] = binding
            var w = ProtobufWriter(); w.uint32(2, 0, skipZero: false)
            reply = Self.response(id, 5, w.bytes)
        case (5, 4): // keymap.save_changes
            saves += 1
            var ok = ProtobufWriter(); ok.bool(1, true)
            var w = ProtobufWriter(); w.message(4, ok.bytes)
            reply = Self.response(id, 5, w.bytes)
        case (5, 5): // keymap.discard_changes
            discards += 1
            var w = ProtobufWriter(); w.bool(5, true)
            reply = Self.response(id, 5, w.bytes)
        default:
            XCTFail("unexpected request: subsystem \(subsystem), call \(call)")
            return
        }
        outgoing.append(reply)
    }

    /// The first field of a subsystem request, and its body when it has one.
    private static func call(in body: [UInt8]) throws -> (Int, [UInt8]) {
        var r = ProtobufReader(body)
        guard !r.isAtEnd else { return (0, []) }
        let (field, type) = try r.nextField()
        if type == .lengthDelimited { return (field, try r.bytesField()) }
        try r.skip(type)
        return (field, [])
    }

    /// Response{request_response = 1 {request_id = 1, <subsystem> = payload}}
    private static func response(_ id: UInt32, _ subsystem: Int, _ payload: [UInt8]) -> [UInt8] {
        var inner = ProtobufWriter()
        inner.uint32(1, id, skipZero: false)
        inner.message(subsystem, payload)
        var w = ProtobufWriter(); w.message(1, inner.bytes)
        return w.bytes
    }
}

final class WinKeyboardTests: XCTestCase {
    private let kp: Int32 = 5, trans: Int32 = 1, bt: Int32 = 2

    private func makeFirmware(locked: Bool) -> FakeFirmware {
        var base = Array(repeating: BehaviorBinding(behaviorID: trans, param1: 0, param2: 0), count: 79)
        base[36] = BehaviorBinding(behaviorID: kp, param1: HIDKeycodes.encode(usage: 0x04), param2: 0) // A
        var fn = Array(repeating: BehaviorBinding(behaviorID: trans, param1: 0, param2: 0), count: 79)
        fn[19] = BehaviorBinding(behaviorID: bt, param1: 3, param2: 0)
        return FakeFirmware(
            locked: locked,
            layers: [KeymapLayer(id: 0, name: "Base", bindings: base), KeymapLayer(id: 1, name: "Fn", bindings: fn)],
            behaviors: [BehaviorInfo(id: kp, displayName: "Key Press", param1: .hidUsage),
                        BehaviorInfo(id: trans, displayName: "Transparent", param1: .none),
                        BehaviorInfo(id: bt, displayName: "Bluetooth", param1: .other)])
    }

    private func keyboard(on firmware: FakeFirmware) -> WinKeyboard {
        let keyboard = WinKeyboard()
        keyboard.discover = {
            let client = StudioClient(transport: firmware)
            var info = DeviceInfo()
            info.name = "M0110"
            return (client, info)
        }
        return keyboard
    }

    /// Runs the app thread's queue until `condition` holds: in the app, the
    /// Win32 loop does this.
    private func wait(_ what: String, timeout: TimeInterval = 8, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Main.drain()
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("timed out waiting for \(what)")
    }

    func testLockedThenUnlockedLoadsTheKeymap() {
        let firmware = makeFirmware(locked: true)
        let keyboard = keyboard(on: firmware)
        keyboard.connect()
        wait("connected and locked") { keyboard.connection.isConnected && keyboard.lockState == .locked }
        XCTAssertEqual(keyboard.connection, .connected(port: "COM9", device: "M0110"))
        XCTAssertTrue(keyboard.layers.isEmpty, "Studio refuses reads while locked")

        firmware.setLocked(false)
        wait("the keymap after the unlock") { keyboard.layers.count == 2 }
        XCTAssertEqual(keyboard.lockState, .unlocked)
        XCTAssertEqual(keyboard.layers[0].slots["36"]?.legend, LegendJSON(.single("A")))
        XCTAssertEqual(keyboard.layers[1].slots["19"]?.legend, LegendJSON(.word("BT")))
        XCTAssertEqual(keyboard.layers[1].slots["19"]?.editable, false)
        keyboard.disconnect()
        wait("disconnected") { keyboard.connection == .disconnected }
    }

    func testRebindSaveAndTheEmptySlot() {
        let firmware = makeFirmware(locked: false)
        let keyboard = keyboard(on: firmware)
        keyboard.connect()
        wait("the keymap") { keyboard.layers.count == 2 }

        let b = HIDKeycodes.encode(usage: 0x05)
        keyboard.rebind(layerIndex: 0, position: 36, to: b)
        wait("the edit") { keyboard.pendingEdits == 1 }
        XCTAssertEqual(firmware.binding(layer: 0, position: 36).param1, b)
        XCTAssertEqual(keyboard.layers[0].slots["36"]?.legend, LegendJSON(.single("B")))
        XCTAssertEqual(keyboard.status, "Set key 36 to B")

        // A transparent slot becomes a key press.
        let mute = HIDKeycodes.encode(page: HIDKeycodes.consumerPage, usage: 0xE2)
        keyboard.rebind(layerIndex: 1, position: 20, to: mute)
        wait("the second edit") { keyboard.pendingEdits == 2 }
        XCTAssertEqual(firmware.binding(layer: 1, position: 20), BehaviorBinding(behaviorID: kp, param1: mute, param2: 0))

        // A Bluetooth key has no keycode to change.
        keyboard.rebind(layerIndex: 1, position: 19, to: b)
        Main.drain()
        XCTAssertEqual(keyboard.status, "Bluetooth does not take a keycode parameter")
        XCTAssertEqual(firmware.binding(layer: 1, position: 19).behaviorID, bt)

        keyboard.save()
        wait("the save") { keyboard.pendingEdits == 0 }
        XCTAssertEqual(firmware.saves, 1)
        XCTAssertEqual(keyboard.status, "Saved to the keyboard's flash")
        keyboard.disconnect()
        wait("disconnected") { keyboard.connection == .disconnected }
    }

    func testRelockStopsEditing() {
        let firmware = makeFirmware(locked: false)
        let keyboard = keyboard(on: firmware)
        keyboard.connect()
        wait("the keymap") { keyboard.layers.count == 2 }

        firmware.setLocked(true)
        wait("the lock") { keyboard.lockState == .locked }
        XCTAssertEqual(keyboard.status, "Studio locked again. Press the key bound to &studio_unlock to keep editing.")
        XCTAssertEqual(keyboard.layers.count, 2, "the board stays, dimmed")

        keyboard.rebind(layerIndex: 0, position: 36, to: HIDKeycodes.encode(usage: 0x05))
        XCTAssertEqual(keyboard.status, "Keyboard is locked. Press the key bound to &studio_unlock")
        XCTAssertEqual(firmware.binding(layer: 0, position: 36).param1, HIDKeycodes.encode(usage: 0x04))
        keyboard.disconnect()
        wait("disconnected") { keyboard.connection == .disconnected }
    }
}
