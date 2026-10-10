import Foundation
import XCTest

@testable import M0110HUD

// The Windows clipboard courier against the keyboard's frames, as
// helper/PROTOCOL.md describes them, with a clipboard and a clock of the
// test's own.

private final class FakeClipboard: ClipboardAccess {
    private(set) var sequence: UInt32 = 1
    var content: ClipboardRead = .nothing
    private(set) var written: [ClipboardRead] = []

    /// Something copied by another program.
    func copy(_ value: ClipboardRead) {
        content = value
        sequence += 1
    }

    func read() -> ClipboardRead { content }

    func write(text: [UInt8]) -> Bool {
        content = .text(text)
        written.append(content)
        sequence += 1
        return true
    }

    func write(image: Data) -> Bool {
        content = .png(image)
        written.append(content)
        sequence += 1
        return true
    }
}

/// Runs scheduled work when told to, in time order.
private final class Clock {
    private var now: TimeInterval = 0
    private var next: UInt32 = 1
    private var pending: [(id: UInt32, at: TimeInterval, work: () -> Void)] = []

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) -> UInt32 {
        defer { next += 1 }
        pending.append((next, now + delay, work))
        return next
    }

    func cancel(_ id: UInt32) { pending.removeAll { $0.id == id } }

    func advance(_ seconds: TimeInterval) {
        let end = now + seconds
        while let due = pending.filter({ $0.at <= end }).min(by: { $0.at < $1.at }) {
            pending.removeAll { $0.id == due.id }
            now = due.at
            due.work()
        }
        now = end
    }
}

final class WinClipCourierTests: XCTestCase {
    private var clipboard: FakeClipboard!
    private var clock: Clock!
    private var courier: WinClipCourier!
    private var frames: [[UInt8]] = []
    private var clips: [(payload: [UInt8], flags: UInt8)] = []
    private var shrinks = 0

    override func setUp() {
        clipboard = FakeClipboard()
        clock = Clock()
        frames = []
        clips = []
        shrinks = 0
        courier = WinClipCourier(clipboard: clipboard)
        courier.send = { [unowned self] in self.frames.append([UInt8]($0)) }
        courier.sendClip = { [unowned self] in self.clips.append(($0, $1)) }
        courier.frameCap = { 64 }
        courier.schedule = { [unowned self] in self.clock.schedule($0, $1) }
        courier.cancel = { [unowned self] in self.clock.cancel($0) }
        courier.shrink = { [unowned self] content, budget, done in
            self.shrinks += 1
            done(ClipContent(kind: .jpeg, data: Data(content.data.prefix(budget))))
        }
        // STATUS: version 2, 16384 bytes of text, 1024 of opaque.
        courier.receive([ClipWire.Frame.status.rawValue, 2] + ClipWire.le16(16384) + ClipWire.le16(1024))
        courier.start()
    }

    /// A clip as the keyboard delivers it, in frames.
    private func deliver(_ payload: [UInt8], opaque: Bool = false) -> UInt32 {
        for frame in ClipWire.transfer(payload, flags: opaque ? ClipWire.opaque : 0, frameCap: 64) {
            courier.receive([UInt8](frame))
        }
        return ClipWire.crc32(payload)
    }

    private func relay(_ datagram: ClipDatagram) {
        courier.receive([ClipWire.Frame.relay.rawValue] + datagram.encoded(room: 63))
    }

    private var lastFrameTypes: [UInt8] { frames.compactMap(\.first) }

    // MARK: Copies made here

    func testTextCopiedHereGoesToTheKeyboard() {
        clipboard.copy(.text(Array("hello\nworld".utf8)))
        courier.checkClipboard()
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips.first?.payload, Array("hello\nworld".utf8))
        XCTAssertEqual(clips.first?.flags, ClipWire.usbKnown)
    }

    func testAConcealedCopyClearsTheKeyboard() {
        clipboard.copy(.concealed)
        courier.checkClipboard()
        XCTAssertTrue(clips.isEmpty)
        XCTAssertEqual(frames, [[ClipWire.Frame.clear.rawValue]])
    }

    func testAnImageIsOfferedThenSentThroughTheKeyboardWhenAsked() throws {
        let png = Data(repeating: 0x89, count: 5000)
        clipboard.copy(.png(png))
        courier.checkClipboard()
        let offerClip = try XCTUnwrap(clips.first)
        XCTAssertNotEqual(offerClip.flags & ClipWire.opaque, 0)
        guard case let .offer(kind, id, _, port, addresses)? = ClipMessage(offerClip.payload) else {
            return XCTFail("not an OFFER")
        }
        XCTAssertEqual(kind, .png)
        XCTAssertEqual(port, 0, "there is no network to fetch over")
        XCTAssertEqual(addresses, [])

        relay(.want(id: id, port: 51234, addresses: []))
        XCTAssertEqual(shrinks, 1)
        let inlineClip = try XCTUnwrap(clips.last)
        guard case let .inline(inlineKind, inlineID, content)? = ClipMessage(inlineClip.payload) else {
            return XCTFail("not an INLINE")
        }
        XCTAssertEqual(inlineKind, .jpeg)
        XCTAssertEqual(inlineID, id)
        XCTAssertLessThanOrEqual(content.count + ClipMessage.inlineOverhead, 1024)
    }

    func testAWantForAnOlderCopyIsAnsweredGone() {
        relay(.want(id: [1, 2, 3, 4, 5, 6, 7, 8], port: 0, addresses: []))
        XCTAssertEqual(frames.last, [ClipWire.Frame.relay.rawValue] + ClipDatagram.gone(id: [1, 2, 3, 4, 5, 6, 7, 8]).encoded(room: 63))
    }

    // MARK: Copies made elsewhere

    func testDeliveredTextIsPlacedAcknowledgedAndNotSentBack() {
        let crc = deliver(Array("from the Mac".utf8))
        XCTAssertEqual(clipboard.written, [.text(Array("from the Mac".utf8))])
        XCTAssertEqual(frames.last, [UInt8](ClipWire.ack(crc: crc)))
        courier.checkClipboard()
        XCTAssertTrue(clips.isEmpty, "a delivered clip is not a new copy")
    }

    func testAnOfferIsAskedForThroughTheKeyboardAndTheInlineTaken() {
        let id: [UInt8] = [9, 9, 9, 9, 9, 9, 9, 9]
        _ = deliver(ClipMessage.offer(kind: .text, id: id, key: Array(repeating: 7, count: 32), port: 40000,
                                      addresses: []).encoded, opaque: true)
        XCTAssertEqual(frames[0], [UInt8](ClipWire.hold(ClipWire.holdSoon)))
        XCTAssertEqual(frames[1], [ClipWire.Frame.relay.rawValue] + ClipDatagram.want(id: id, port: 0, addresses: []).encoded(room: 63))
        XCTAssertTrue(courier.busy)

        clock.advance(1)
        XCTAssertTrue(lastFrameTypes.filter { $0 == ClipWire.Frame.hold.rawValue }.count >= 3, "holds repeat")

        let content = Array("a long text".utf8)
        let crc = deliver(ClipMessage.inline(kind: .text, id: id, content: content).encoded, opaque: true)
        XCTAssertEqual(clipboard.written, [.text(content)])
        XCTAssertEqual(frames.last, [UInt8](ClipWire.ack(crc: crc)))
        XCTAssertFalse(courier.busy)

        let count = frames.count
        clock.advance(10)
        XCTAssertEqual(frames.count, count, "no holds after the content came")
    }

    func testAFetchThatNeverCompletesGivesUp() {
        let offer = ClipMessage.offer(kind: .png, id: [1, 1, 1, 1, 1, 1, 1, 1], key: Array(repeating: 2, count: 32),
                                      port: 0, addresses: []).encoded
        let crc = deliver(offer, opaque: true)
        clock.advance(WinClipCourier.soonFor + 0.1)
        XCTAssertEqual(frames.last, [UInt8](ClipWire.hold(0)), "past 2.5 s a paste is no longer held")
        clock.advance(WinClipCourier.inlineWait)
        XCTAssertEqual(Array(frames.suffix(2)), [[UInt8](ClipWire.hold(ClipWire.holdOff)), [UInt8](ClipWire.ack(crc: crc))])
        XCTAssertFalse(courier.busy)
    }

    func testCopyingHereDuringAFetchCancelsIt() {
        let id: [UInt8] = [3, 3, 3, 3, 3, 3, 3, 3]
        _ = deliver(ClipMessage.offer(kind: .png, id: id, key: Array(repeating: 4, count: 32), port: 0,
                                      addresses: []).encoded, opaque: true)
        frames.removeAll()
        clipboard.copy(.text(Array("newer".utf8)))
        courier.checkClipboard()
        XCTAssertEqual(frames[0], [ClipWire.Frame.relay.rawValue] + ClipDatagram.cancel(id: id).encoded(room: 63))
        XCTAssertEqual(frames[1], [UInt8](ClipWire.hold(ClipWire.holdOff)))
        XCTAssertEqual(clips.last?.payload, Array("newer".utf8))

        // The INLINE turns up anyway: acknowledged, not placed.
        let crc = deliver(ClipMessage.inline(kind: .text, id: id, content: Array("old".utf8)).encoded, opaque: true)
        XCTAssertTrue(clipboard.written.isEmpty)
        XCTAssertEqual(frames.last, [UInt8](ClipWire.ack(crc: crc)))
    }

    func testANewerCopyHereIsNotOverwrittenByADelivery() {
        clipboard.copy(.text(Array("mine".utf8)))
        let crc = deliver(Array("theirs".utf8))
        XCTAssertTrue(clipboard.written.isEmpty)
        XCTAssertNotEqual(frames.last, [UInt8](ClipWire.ack(crc: crc)), "left for the keyboard to type")
        XCTAssertEqual(clips.last?.payload, Array("mine".utf8))
    }
}
