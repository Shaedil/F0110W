import Darwin
import XCTest

@testable import M0110HUD

// From zmk-studio-messages: zmk.studio.Response{request_response = 1 | notification = 2}.

private func reply(to id: UInt32, keymap body: [UInt8]) -> [UInt8] {
    var inner = ProtobufWriter()
    inner.uint32(1, id, skipZero: false)
    inner.message(5, body)
    var w = ProtobufWriter()
    w.message(1, inner.bytes)
    return w.bytes
}

/// keymap.Response{set_layer_binding = 2 SET_LAYER_BINDING_RESP_OK}
private func bindingAccepted(_ id: UInt32) -> [UInt8] {
    var body = ProtobufWriter()
    body.uint32(2, 0, skipZero: false)
    return reply(to: id, keymap: body.bytes)
}

/// Notification{keymap = 5 {unsaved_changes_status_changed = 1}}, sent during set_layer_binding.
private let unsavedChanges: [UInt8] = {
    var keymap = ProtobufWriter(); keymap.bool(1, true)
    var n = ProtobufWriter(); n.message(5, keymap.bytes)
    var w = ProtobufWriter(); w.message(2, n.bytes)
    return w.bytes
}()

/// Notification{core = 2 {lock_state_changed = 1}}
private func lockChanged(_ lock: LockState) -> [UInt8] {
    var core = ProtobufWriter(); core.uint32(1, lock.rawValue, skipZero: false)
    var n = ProtobufWriter(); n.message(2, core.bytes)
    var w = ProtobufWriter(); w.message(2, n.bytes)
    return w.bytes
}

/// zmk.studio.Request{request_id = 1}
private func requestID(_ frame: [UInt8]) -> UInt32 {
    var r = ProtobufReader(frame)
    while !r.isAtEnd {
        guard let (field, type) = try? r.nextField() else { break }
        if field == 1, type == .varint, let id = try? r.varint() { return UInt32(id) }
        try? r.skip(type)
    }
    return 0
}

private let aBinding = BehaviorBinding(behaviorID: 5, param1: HIDKeycodes.encode(usage: 0x68), param2: 0)

private final class ScriptedTransport: StudioTransport {
    var label = "scripted"
    var isOpen = true
    var responseTimeout: TimeInterval = 0.2
    var frames: [[UInt8]] = []
    var answer: (UInt32) -> [[UInt8]] = { _ in [] }

    func open() throws {}
    func close() {}
    func send(_ payload: [UInt8]) throws { frames += answer(requestID(payload)) }
    func receiveFrame(timeout: TimeInterval) throws -> [UInt8] {
        guard !frames.isEmpty else { throw StudioError.timeout("scripted frame") }
        return frames.removeFirst()
    }
    func receiveFrameIfAvailable() throws -> [UInt8]? {
        frames.isEmpty ? nil : frames.removeFirst()
    }
}

final class StudioClientTests: XCTestCase {
    /// The firmware writes the notification and the reply back to back, so one
    /// USB read often returns both frames. Both must be kept.
    func testBindingReplyArrivingInTheSameReadAsANotificationIsKept() throws {
        var master: Int32 = -1, slave: Int32 = -1
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
        defer { Darwin.close(master); Darwin.close(slave) }
        let path = String(cString: ptsname(master))
        let port = master

        let firmware = Thread {
            var decoder = StudioFraming.Decoder()
            var byte: UInt8 = 0
            while Darwin.read(port, &byte, 1) == 1 {
                guard let request = decoder.feed(byte) else { continue }
                let both = StudioFraming.wrap(unsavedChanges)
                    + StudioFraming.wrap(bindingAccepted(requestID(request)))
                _ = both.withUnsafeBufferPointer { Darwin.write(port, $0.baseAddress, $0.count) }
                return
            }
        }
        firmware.start()

        let client = StudioClient(port: path)
        try client.open()
        defer { client.close() }
        XCTAssertNoThrow(try client.setBinding(layerID: 0, keyPosition: 0, binding: aBinding))
    }

    func testLockChangeAnnouncedDuringARequestIsReported() throws {
        let transport = ScriptedTransport()
        transport.answer = { [lockChanged(.unlocked), bindingAccepted($0)] }
        let client = StudioClient(transport: transport)
        var announced: [LockState] = []
        client.onLockStateChanged = { announced.append($0) }

        try client.setBinding(layerID: 0, keyPosition: 3, binding: aBinding)
        XCTAssertEqual(announced, [.unlocked])
    }

    /// Reading the idle re-lock must not send a request, which would reset the idle timer.
    func testIdleRelockIsReadWithoutSendingARequest() throws {
        let transport = ScriptedTransport()
        transport.frames = [lockChanged(.locked)]
        var sent = 0
        transport.answer = { _ in sent += 1; return [] }
        let client = StudioClient(transport: transport)
        var announced: [LockState] = []
        client.onLockStateChanged = { announced.append($0) }

        try client.readNotifications()
        XCTAssertEqual(announced, [.locked])
        XCTAssertEqual(sent, 0)
    }

    func testOtherNotificationsAreNotTakenForALockChange() throws {
        let transport = ScriptedTransport()
        transport.frames = [unsavedChanges, bindingAccepted(99)]
        let client = StudioClient(transport: transport)
        var announced: [LockState] = []
        client.onLockStateChanged = { announced.append($0) }

        try client.readNotifications()
        XCTAssertEqual(announced, [])
    }
}
