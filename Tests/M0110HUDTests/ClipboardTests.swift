import AppKit
import Network
import XCTest

@testable import M0110HUD

private func hex(_ string: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        bytes.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}

/// The values the vectors in helper/PROTOCOL.md are made with.
private let vectorID: [UInt8] = Array(0...7)
private let vectorKey: [UInt8] = Array(0x10...0x2F)

final class ClipMessageTests: XCTestCase {
    func testOfferMatchesTheDocumentedVector() throws {
        let v4 = try XCTUnwrap(ClipAddress([192, 168, 1, 20]))
        let v6 = try XCTUnwrap(ClipAddress(hex("fd000000000000000000000000001234")))
        let offer = ClipMessage.offer(kind: .png, id: vectorID, key: vectorKey, port: 51234,
                                      addresses: [v4, v6])
        let vector = hex(
            "01020001020304050607101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f"
                + "22c80204c0a8011406fd000000000000000000000000001234")

        XCTAssertEqual(offer.encoded, vector)
        XCTAssertEqual(ClipMessage(vector), offer)
    }

    func testWantMatchesTheDocumentedVector() throws {
        let address = try XCTUnwrap(ClipAddress([10, 0, 0, 7]))
        let want = ClipDatagram.want(id: vectorID, port: 40000, addresses: [address])
        let vector = hex("010001020304050607409c01040a000007")

        XCTAssertEqual(want.encoded(room: 63), vector)
        XCTAssertEqual(ClipDatagram(vector), want)
    }

    func testWantLeavesOutAddressesThatDoNotFit() throws {
        let v4 = try XCTUnwrap(ClipAddress([10, 0, 0, 7]))
        let v6 = try XCTUnwrap(ClipAddress([UInt8](repeating: 0xFD, count: 16)))
        let want = ClipDatagram.want(id: vectorID, port: 1, addresses: [v4, v6, v4])

        // Room for the first and not the second; the third would fit and is
        // still not slipped in past it out of order.
        XCTAssertEqual(ClipDatagram(want.encoded(room: 22)),
                       .want(id: vectorID, port: 1, addresses: [v4]))
        XCTAssertEqual(ClipDatagram(want.encoded(room: 12)),
                       .want(id: vectorID, port: 1, addresses: []))
        XCTAssertLessThanOrEqual(want.encoded(room: 63).count, 63)
        XCTAssertEqual(ClipDatagram(want.encoded(room: 63)), want)
    }

    func testInlineAndGoneRoundTrip() {
        let inline = ClipMessage.inline(kind: .jpeg, id: vectorID, content: [9, 8, 7])
        XCTAssertEqual(inline.encoded, [2, 3] + vectorID + [9, 8, 7])
        XCTAssertEqual(ClipMessage(inline.encoded), inline)

        let gone = ClipDatagram.gone(id: vectorID)
        XCTAssertEqual(gone.encoded(room: 63), [2] + vectorID)
        XCTAssertEqual(ClipDatagram(gone.encoded(room: 63)), gone)

        let cancel = ClipDatagram.cancel(id: vectorID)
        XCTAssertEqual(cancel.encoded(room: 63), [3] + vectorID)
        XCTAssertEqual(ClipDatagram(cancel.encoded(room: 63)), cancel)
    }

    func testMalformedInputIsRefused() {
        let offer = ClipMessage.offer(kind: .text, id: vectorID, key: vectorKey, port: 1,
                                      addresses: [ClipAddress([1, 2, 3, 4])!]).encoded

        XCTAssertNil(ClipMessage([]))
        XCTAssertNil(ClipMessage([1, 2, 3]))
        XCTAssertNil(ClipMessage([9, 1] + vectorID))
        XCTAssertNil(ClipMessage([1, 99] + vectorID + vectorKey + [0, 0, 0]))
        // Cut off in the middle of an address, and with an unknown family.
        XCTAssertNil(ClipMessage(Array(offer.dropLast())))
        XCTAssertNil(ClipMessage(Array(offer.dropLast(5)) + [7, 1, 2, 3, 4]))
        XCTAssertNil(ClipDatagram([1] + vectorID))
        XCTAssertNil(ClipDatagram([4] + vectorID))
        XCTAssertNil(ClipDatagram([2, 0, 1]))
    }
}

final class ClipOutboxTests: XCTestCase {
    private func drain(_ outbox: inout ClipOutbox) -> [UInt8] {
        var order: [UInt8] = []
        while let frame = outbox.next() { order.append(frame[0]) }
        return order
    }

    func testWhatIsNotPartOfAClipGoesAheadOfOne() {
        var outbox = ClipOutbox()
        XCTAssertTrue(outbox.isEmpty)
        XCTAssertNil(outbox.next())

        outbox.send(Data([1]))
        outbox.sendClip([Data([10]), Data([11]), Data([12])])
        XCTAssertEqual(outbox.next(), Data([1]))
        XCTAssertEqual(outbox.next(), Data([10]))

        // Queued once the clip is under way: next out, in the order queued.
        outbox.send(Data([2]))
        outbox.send(Data([3]))
        XCTAssertFalse(outbox.isEmpty)
        XCTAssertEqual(drain(&outbox), [2, 3, 11, 12])
        XCTAssertTrue(outbox.isEmpty)
    }

    func testNewerClipReplacesWhatIsLeftOfTheLast() {
        var outbox = ClipOutbox()

        outbox.sendClip([Data([10]), Data([11]), Data([12])])
        _ = outbox.next()
        outbox.send(Data([1]))
        outbox.sendClip([Data([20]), Data([21])])
        XCTAssertEqual(drain(&outbox), [1, 20, 21])

        outbox.sendClip([Data([30])])
        outbox.send(Data([2]))
        outbox.dropClip()
        XCTAssertEqual(drain(&outbox), [2])

        outbox.sendClip([Data([40])])
        outbox.send(Data([3]))
        outbox.removeAll()
        XCTAssertTrue(outbox.isEmpty)
    }
}

final class ClipStreamTests: XCTestCase {
    private let record0 = hex("0017000000607f787e815ec174019f43e6bffb11c2ecfbffa81efddf")
    private let record1 = hex("0115000000100a35e63e77753531f04ac52596a7a96c6b099f1d")

    private func open(_ records: [[UInt8]], key: [UInt8] = vectorKey) -> Data? {
        var opener = ClipStream.Opener(id: vectorID, key: key)
        for record in records {
            guard ClipStream.Opener.sealedLength(header: Data(record.prefix(5)))
                    == record.count - 5,
                  opener.open(last: record[0], sealed: Data(record.dropFirst(5)))
            else { return nil }
        }
        return opener.content
    }

    func testOpensTheDocumentedVector() {
        XCTAssertEqual(open([record0, record1]), Data("hello, world".utf8))
    }

    func testSealsEmptyContentAsTheDocumentedVector() {
        XCTAssertEqual([UInt8](ClipStream.seal(Data(), id: vectorID, key: vectorKey)),
                       hex("0110000000570bfcee544eff0e3cf8e15b02478f22"))
    }

    func testWhatIsSealedOpens() {
        // Long enough for three records.
        let content = Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let stream = [UInt8](ClipStream.seal(content, id: vectorID, key: vectorKey))
        var records: [[UInt8]] = []
        var cursor = 0

        while cursor < stream.count {
            let length = Int(ClipWire.readLE32(stream, at: cursor + 1))
            records.append(Array(stream[cursor..<(cursor + 5 + length)]))
            cursor += 5 + length
        }

        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map { $0[0] }, [0, 0, 1])
        XCTAssertEqual(open(records), content)
    }

    func testTamperingFailsTheStream() {
        var flipped = record1
        flipped[7] ^= 1
        var relabelled = record0
        relabelled[0] = 1

        XCTAssertNil(open([record0, flipped]))
        // Passing a record off as the final one, to cut the content short.
        XCTAssertNil(open([relabelled]))
        // Out of order, replayed, and under another key.
        XCTAssertNil(open([record1, record0]))
        XCTAssertNil(open([record0, record0]))
        XCTAssertNil(open([record0, record1], key: Array(0x11...0x30)))
    }

    func testHeadersAnnouncingNonsenseAreRefused() {
        XCTAssertNil(ClipStream.Opener.sealedLength(header: Data([0, 15, 0, 0, 0])))
        XCTAssertNil(ClipStream.Opener.sealedLength(header: Data([0, 0x11, 0, 1, 0])))
        XCTAssertNil(ClipStream.Opener.sealedLength(header: Data([2, 16, 0, 0, 0])))
        XCTAssertEqual(ClipStream.Opener.sealedLength(header: Data([1, 0x10, 0, 1, 0])), 65552)
    }
}

/// Spins the main run loop until `condition` holds.
private func waitFor(_ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath,
                  line: UInt = #line, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(condition(), "timed out waiting for \(what)", file: file, line: line)
}

private func settle(_ interval: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(interval))
}

private let loopback = ClipAddress([127, 0, 0, 1])!
/// TEST-NET-1: routed nowhere, so a connection to it never comes up.
private let nowhere = ClipAddress([192, 0, 2, 1])!

/// A listener that takes connections and says nothing: a helper that has
/// hung, or a network that swallows everything after the handshake.
private final class SilentListener {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    /// Close a connection once this many bytes have come in on it, without
    /// a word in reply.
    private let closeAfter: Int?

    private(set) var accepted = 0
    private(set) var closedByPeer = 0
    private(set) var received = 0

    var port: UInt16? { listener.port?.rawValue }

    init(closeAfter: Int? = nil) throws {
        self.closeAfter = closeAfter
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.accepted += 1
            self.connections.append(connection)
            connection.start(queue: .main)
            self.read(connection, soFar: 0)
        }
        listener.start(queue: .main)
    }

    private func read(_ connection: NWConnection, soFar: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, complete, error in
            guard let self else { return }
            let total = soFar + (data?.count ?? 0)
            self.received += data?.count ?? 0

            if complete || error != nil {
                self.closedByPeer += 1
                connection.cancel()
            } else if let closeAfter = self.closeAfter, total >= closeAfter {
                connection.cancel()
            } else {
                self.read(connection, soFar: total)
            }
        }
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
    }
}

final class ClipChannelTests: XCTestCase {
    private func silent(closeAfter: Int? = nil) throws -> SilentListener {
        let listener = try SilentListener(closeAfter: closeAfter)
        waitFor("the silent listener") { listener.port != nil }
        addTeardownBlock { listener.stop() }
        return listener
    }

    func testStreamThatStallsIsGivenUpOn() throws {
        let source = try silent()
        let receiver = channel()
        var fetched: Data??

        receiver.idleTimeout = 0.4
        receiver.fetch(id: vectorID, key: vectorKey, from: [loopback], port: source.port!) {
            fetched = $0
        }
        waitFor("the fetch to be given up on", timeout: 3) { fetched != nil }
        XCTAssertEqual(fetched, .some(nil))
        // And the connection is not left open behind it.
        waitFor("the connection to close") { source.closedByPeer == 1 }

        // Handing over to a peer that never reads to the end is the same.
        var taken: Bool?
        receiver.push(id: vectorID, key: vectorKey, content: Data(count: 200), to: [loopback],
                      port: source.port!) { taken = $0 }
        waitFor("the push to be given up on", timeout: 3) { taken != nil }
        XCTAssertEqual(taken, false)
        waitFor("that connection to close") { source.closedByPeer == 2 }
    }

    func testFetchThatIsCalledOffStopsThere() throws {
        let source = try silent()
        let receiver = channel()
        var called = false

        let callOff = receiver.fetch(id: vectorID, key: vectorKey, from: [loopback],
                                     port: source.port!) { _ in called = true }
        waitFor("the connection") { source.accepted == 1 && source.received > 0 }
        callOff()
        waitFor("the connection to close") { source.closedByPeer == 1 }
        settle(0.3)
        XCTAssertFalse(called)

        // Called off before anything has connected.
        let early = receiver.fetch(id: vectorID, key: vectorKey, from: [nowhere], port: 9) { _ in
            called = true
        }
        early()
        settle(ClipChannel.connectTimeout + 0.3)
        XCTAssertFalse(called)
    }

    func testPushIsNotTakenUnlessTheReceiverSaysSo() throws {
        let content = Data(count: 1000)
        // Reads the whole stream and closes, as a receiver that could not
        // open it, or did not want it, does.
        let stream = 14 + ClipStream.headerLength + content.count + ClipStream.tagLength
        let receiver = try silent(closeAfter: stream)
        var taken: Bool?

        channel().push(id: vectorID, key: vectorKey, content: content, to: [loopback],
                       port: receiver.port!) { taken = $0 }
        waitFor("the push") { taken != nil }
        XCTAssertEqual(taken, false)
        XCTAssertEqual(receiver.received, stream)
    }

    func testContentPastTheBoundIsRefused() {
        let source = channel()
        let receiver = channel()
        let content = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
        var over: Data??
        var exactly: Data??

        source.offering = (vectorID, vectorKey, { content })
        receiver.maxContent = content.count - 1
        receiver.fetch(id: vectorID, key: vectorKey, from: [loopback], port: source.port!) {
            over = $0
        }
        waitFor("the fetch past the bound") { over != nil }
        XCTAssertEqual(over, .some(nil))

        receiver.maxContent = content.count
        receiver.fetch(id: vectorID, key: vectorKey, from: [loopback], port: source.port!) {
            exactly = $0
        }
        waitFor("the fetch at the bound") { exactly != nil }
        XCTAssertEqual(exactly, content)
    }

    func testPeerThatNeverSaysWhatForIsDropped() {
        let listener = ClipChannel()
        listener.helloTimeout = 0.3
        listener.start()
        waitFor("the listener") { listener.port != nil }
        addTeardownBlock { listener.stop() }

        let connection = NWConnection(host: .ipv4(.loopback),
                                      port: NWEndpoint.Port(rawValue: listener.port!)!, using: .tcp)
        var closed = false
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
            closed = complete || error != nil
        }
        addTeardownBlock { connection.cancel() }
        waitFor("the listener to hang up", timeout: 3) { closed }
    }

    private func channel() -> ClipChannel {
        let channel = ClipChannel()
        channel.start()
        waitFor("the listener") { channel.port != nil }
        addTeardownBlock { channel.stop() }
        return channel
    }

    func testGetFetchesWhatIsOnOffer() {
        let source = channel()
        let receiver = channel()
        let content = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
        var asked = 0
        var fetched: Data??

        source.offering = (vectorID, vectorKey, { asked += 1; return content })
        receiver.fetch(id: vectorID, key: vectorKey, from: [nowhere, loopback],
                       port: source.port!) { fetched = $0 }

        waitFor("the fetch") { fetched != nil }
        XCTAssertEqual(fetched, content)
        XCTAssertEqual(asked, 1)
    }

    func testGetForAnotherCopyOrUnderAnotherKeyComesBackEmpty() {
        let source = channel()
        let receiver = channel()
        var wrongID: Data??
        var wrongKey: Data??

        source.offering = (vectorID, vectorKey, { Data("secret".utf8) })
        receiver.fetch(id: Array(1...8), key: vectorKey, from: [loopback], port: source.port!) {
            wrongID = $0
        }
        receiver.fetch(id: vectorID, key: Array(0x11...0x30), from: [loopback],
                       port: source.port!) { wrongKey = $0 }

        waitFor("both fetches") { wrongID != nil && wrongKey != nil }
        XCTAssertEqual(wrongID, .some(nil))
        XCTAssertEqual(wrongKey, .some(nil))
    }

    func testFetchGivesUpWhenNothingAnswers() {
        let receiver = channel()
        var fetched: Data??
        let started = Date()

        receiver.fetch(id: vectorID, key: vectorKey, from: [nowhere], port: 9) { fetched = $0 }
        waitFor("the fetch to give up") { fetched != nil }
        XCTAssertEqual(fetched, .some(nil))
        XCTAssertLessThan(Date().timeIntervalSince(started), ClipChannel.connectTimeout + 1)

        fetched = nil
        receiver.fetch(id: vectorID, key: vectorKey, from: [], port: 9) { fetched = $0 }
        waitFor("the fetch with nowhere to go") { fetched != nil }
        XCTAssertEqual(fetched, .some(nil))
    }

    func testPutHandsOverWhatIsExpected() {
        let source = channel()
        let receiver = channel()
        let content = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 3) })
        var received: Data?
        var handedOver: Bool?

        receiver.expecting = (vectorID, vectorKey, { received = $0 })
        source.push(id: vectorID, key: vectorKey, content: content, to: [loopback],
                    port: receiver.port!) { handedOver = $0 }

        waitFor("the push") { handedOver != nil && received != nil }
        XCTAssertEqual(received, content)
        XCTAssertEqual(handedOver, true)
    }

    func testPutNobodyAskedForIsRefused() {
        let source = channel()
        let receiver = channel()
        var received: Data?
        var unexpected: Bool?
        var wrongKey: Bool?

        source.push(id: vectorID, key: vectorKey, content: Data("x".utf8), to: [loopback],
                    port: receiver.port!) { unexpected = $0 }
        waitFor("the unexpected push") { unexpected != nil }
        XCTAssertEqual(unexpected, false)

        receiver.expecting = (vectorID, vectorKey, { received = $0 })
        source.push(id: vectorID, key: Array(0x11...0x30), content: Data("x".utf8),
                    to: [loopback], port: receiver.port!) { wrongKey = $0 }
        waitFor("the push under the wrong key") { wrongKey != nil }
        settle(0.1)
        XCTAssertNil(received)
        XCTAssertEqual(wrongKey, false)

        // A different copy from the one being waited for, key or no key.
        var wrongID: Bool?
        source.push(id: Array(1...8), key: vectorKey, content: Data("x".utf8), to: [loopback],
                    port: receiver.port!) { wrongID = $0 }
        waitFor("the push of another copy") { wrongID != nil }
        settle(0.1)
        XCTAssertNil(received)
        XCTAssertEqual(wrongID, false)
    }

    func testLocalAddressesLeaveOutWhatCannotBeReached() {
        func v6(_ first: UInt8, _ second: UInt8, last: UInt8 = 1) -> ClipAddress {
            ClipAddress([first, second] + [UInt8](repeating: 0, count: 13) + [last])!
        }

        XCTAssertTrue(ClipChannel.reachable(ClipAddress([192, 168, 1, 20])!))
        XCTAssertTrue(ClipChannel.reachable(ClipAddress([10, 0, 0, 7])!))
        XCTAssertFalse(ClipChannel.reachable(ClipAddress([127, 0, 0, 1])!))
        XCTAssertFalse(ClipChannel.reachable(ClipAddress([127, 121, 166, 212])!))
        XCTAssertFalse(ClipChannel.reachable(ClipAddress([169, 254, 10, 1])!))
        XCTAssertTrue(ClipChannel.reachable(v6(0xFD, 0x00)))
        XCTAssertTrue(ClipChannel.reachable(v6(0x20, 0x01)))
        XCTAssertFalse(ClipChannel.reachable(v6(0xFE, 0x80)))
        XCTAssertFalse(ClipChannel.reachable(v6(0xFE, 0xBF)))
        XCTAssertFalse(ClipChannel.reachable(v6(0, 0)))
        XCTAssertTrue(ClipChannel.reachable(v6(0, 0, last: 2)))

        let own = ClipChannel.localAddresses()
        XCTAssertTrue(own.allSatisfy(ClipChannel.reachable))
        XCTAssertLessThanOrEqual(own.count, ClipMessage.maxAddresses)
        // IPv4 first.
        XCTAssertEqual(own.map(\.isIPv4), own.map(\.isIPv4).sorted { $0 && !$1 })
    }
}

/// The keyboard as the helpers see it: one clip held, handed to the helper on
/// the selected computer, RELAY passed to the other end, HOLD and ACK noted.
/// The rules are the firmware's, in config/clipboard/clipboard.c.
private final class FakeKeyboard {
    struct Clip {
        let bytes: [UInt8]
        let flags: UInt8
        let crc: UInt32
        let origin: Int
        var delivered: Set<Int> = []
    }

    var version: UInt8 = 2
    var maxText = 16384
    var maxOpaque = 61440
    var frameCaps: [Int: Int] = [:]

    private(set) var clip: Clip?
    private(set) var selected = 0
    private var couriers: [Int: ClipCourier] = [:]
    private var incoming: [Int: ClipAssembler] = [:]
    /// Where the clip in hand, or the one arriving, came from.
    private var origin: Int?
    /// The helper that last sent word to the origin.
    private var requester: Int?

    private(set) var holds: [Int: [UInt8]] = [:]
    private(set) var acks: [Int: [UInt32]] = [:]
    private(set) var relays: [Int: [[UInt8]]] = [:]
    private(set) var clears = 0
    /// Every clip stored, in order: its flags and length.
    private(set) var stored: [(flags: UInt8, length: Int, origin: Int)] = []

    private func cap(_ profile: Int) -> Int { frameCaps[profile] ?? 62 }

    func attach(_ courier: ClipCourier, as profile: Int) {
        couriers[profile] = courier
        courier.frameCap = { [unowned self] in self.cap(profile) }
        courier.send = { [weak self] frame in
            DispatchQueue.main.async { self?.fromHelper(profile, [UInt8](frame)) }
        }
        courier.sendClip = { [weak self] payload, flags in
            guard let self else { return }
            for frame in ClipWire.transfer(payload, flags: flags, frameCap: self.cap(profile)) {
                DispatchQueue.main.async { self.fromHelper(profile, [UInt8](frame)) }
            }
        }
        courier.start()

        var status: [UInt8] = [ClipWire.Frame.status.rawValue, version]
        status += ClipWire.le16(UInt16(maxText))
        if version >= 2 { status += ClipWire.le16(UInt16(maxOpaque)) }
        courier.receive(status)
    }

    func select(_ profile: Int) {
        selected = profile
        deliver()
    }

    /// The helper on `profile` is gone, and the keyboard knows it.
    func detach(_ profile: Int) {
        couriers[profile] = nil
    }

    /// Puts a clip in the keyboard as if the helper on `origin` had sent it.
    func hold(_ bytes: [UInt8], flags: UInt8, from origin: Int) {
        requester = origin == self.origin ? requester : nil
        self.origin = origin
        clip = Clip(bytes: bytes, flags: flags, crc: ClipWire.crc32(bytes), origin: origin)
        stored.append((flags, bytes.count, origin))
        deliver()
    }

    /// Frames of a clip for the helper on `profile`, as far as `frames` of
    /// them: a delivery the keyboard breaks off.
    func deliverPart(_ bytes: [UInt8], to profile: Int, frames: Int) {
        for frame in ClipWire.transfer(bytes, flags: 0, frameCap: cap(profile)).prefix(frames) {
            toHelper(profile, [UInt8](frame))
        }
    }

    private func toHelper(_ profile: Int, _ frame: [UInt8]) {
        DispatchQueue.main.async { [weak self] in self?.couriers[profile]?.receive(frame) }
    }

    private func deliver() {
        guard let clip, clip.origin != selected, couriers[selected] != nil,
              !clip.delivered.contains(selected) else { return }
        for frame in ClipWire.transfer(clip.bytes, flags: clip.flags & ClipWire.opaque,
                                       frameCap: cap(selected)) {
            toHelper(selected, [UInt8](frame))
        }
    }

    private func fromHelper(_ profile: Int, _ frame: [UInt8]) {
        guard let type = ClipWire.Frame(rawValue: frame[0]) else { return }

        switch type {
        case .begin:
            clip = nil
            requester = profile == origin ? requester : nil
            origin = profile
            let length = Int(ClipWire.readLE16(frame, at: 2))
            let limit = frame[1] & ClipWire.opaque != 0 ? maxOpaque : maxText
            var assembler = ClipAssembler()
            if length <= limit {
                assembler.begin(frame)
            } else {
                toHelper(profile, [ClipWire.Frame.result.rawValue, 1, 0, 0, 0, 0])
            }
            incoming[profile] = assembler
            incomingFlags[profile] = frame[1]
        case .data:
            incoming[profile]?.data(frame)
        case .end:
            guard let done = incoming[profile]?.end() else { return }
            clip = Clip(bytes: done.bytes, flags: incomingFlags[profile] ?? 0, crc: done.crc,
                        origin: profile)
            stored.append((incomingFlags[profile] ?? 0, done.bytes.count, profile))
            deliver()
        case .clear:
            clip = nil
            origin = nil
            requester = nil
            clears += 1
        case .ack:
            let crc = ClipWire.readLE32(frame, at: 1)
            acks[profile, default: []].append(crc)
            if clip?.crc == crc { clip?.delivered.insert(profile) }
        case .hold:
            holds[profile, default: []].append(frame[1])
        case .relay:
            var to: Int?
            if let origin {
                if profile != origin {
                    to = origin
                    requester = profile
                } else {
                    to = requester ?? (selected != profile ? selected : nil)
                }
            }
            if let to, couriers[to] != nil, frame.count <= min(ClipWire.relayMax, cap(to)) {
                relays[to, default: []].append(frame)
                toHelper(to, frame)
            } else {
                toHelper(profile,
                         [ClipWire.Frame.result.rawValue, ClipWire.resultUnreachable, 0, 0, 0, 0])
            }
        default:
            break
        }
    }

    private var incomingFlags: [Int: UInt8] = [:]
}

final class ClipCourierTests: XCTestCase {
    private struct Computer {
        let pasteboard: NSPasteboard
        let channel: ClipChannel
        let courier: ClipCourier
        var log: () -> [String]
    }

    private var keyboard: FakeKeyboard!

    override func setUp() {
        keyboard = FakeKeyboard()
    }

    /// A computer with a helper, on `profile`, that tells the other helper it
    /// can be reached at `addresses`.
    private func computer(_ profile: Int, reachableAt addresses: [ClipAddress]) -> Computer {
        let pasteboard = NSPasteboard(name: .init("m0110-test-\(UUID().uuidString)"))
        let channel = ClipChannel()
        var lines: [String] = []
        let courier = ClipCourier(
            pasteboard: pasteboard, channel: channel,
            timing: .init(putWait: 0.3, inlineWait: 6, deliveryIdle: 0.5)) { lines.append($0) }

        courier.localAddresses = { addresses }
        pasteboard.clearContents()
        keyboard.attach(courier, as: profile)
        waitFor("the listener") { channel.port != nil }
        addTeardownBlock {
            courier.stop()
            channel.stop()
            pasteboard.releaseGlobally()
        }
        return Computer(pasteboard: pasteboard, channel: channel, courier: courier,
                        log: { lines })
    }

    /// Noise, so that it does not compress and has to be scaled down to fit
    /// through the keyboard.
    private func noisePNG(side: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: side * 4, bitsPerPixel: 32)!
        var state: UInt32 = 12345

        for index in 0..<(side * side * 4) {
            state = state &* 1_664_525 &+ 1_013_904_223
            rep.bitmapData![index] = index % 4 == 3 ? 255 : UInt8(state >> 24)
        }
        return rep.representation(using: .png, properties: [:])!
    }

    private func copy(image png: Data, on computer: Computer) {
        computer.pasteboard.clearContents()
        computer.pasteboard.setData(png, forType: .png)
        computer.courier.checkPasteboard()
    }

    private func copy(text: String, on computer: Computer) {
        computer.pasteboard.clearContents()
        computer.pasteboard.setString(text, forType: .string)
        computer.courier.checkPasteboard()
    }

    func testTextThatFitsGoesIntoTheKeyboardItself() {
        let a = computer(0, reachableAt: [loopback])
        let b = computer(1, reachableAt: [loopback])

        copy(text: "plain words", on: a)
        waitFor("the clip") { self.keyboard.clip != nil }
        XCTAssertEqual(keyboard.clip?.bytes, Array("plain words".utf8))
        XCTAssertEqual(keyboard.clip!.flags & ClipWire.opaque, 0)

        keyboard.select(1)
        waitFor("delivery") { b.pasteboard.string(forType: .string) == "plain words" }
        waitFor("the acknowledgement") { self.keyboard.acks[1] == [self.keyboard.clip!.crc] }
        XCTAssertNil(keyboard.holds[1])

        // What was put there is not sent back as a copy made there.
        b.courier.checkPasteboard()
        settle(0.2)
        XCTAssertEqual(keyboard.clip?.origin, 0)
    }

    func testImageIsFetchedOverTheNetwork() {
        let a = computer(0, reachableAt: [nowhere, loopback])
        let b = computer(1, reachableAt: [loopback])
        let png = noisePNG(side: 300)

        copy(image: png, on: a)
        waitFor("the offer") { self.keyboard.clip != nil }
        XCTAssertNotEqual(keyboard.clip!.flags & ClipWire.opaque, 0)
        XCTAssertLessThan(keyboard.clip!.bytes.count, 100)
        guard case .offer(let kind, _, _, _, _)? = ClipMessage(keyboard.clip!.bytes) else {
            return XCTFail("not an offer")
        }
        XCTAssertEqual(kind, .png)
        let offerCRC = keyboard.clip!.crc

        keyboard.select(1)
        waitFor("the image") { b.pasteboard.data(forType: .png) == png }
        waitFor("the acknowledgement") { self.keyboard.acks[1] == [offerCRC] }
        // Pastes were held back from the moment the offer arrived.
        XCTAssertEqual(keyboard.holds[1]?.first, ClipWire.holdSoon)
        XCTAssertNil(keyboard.relays[0])
        XCTAssertFalse(b.courier.busy)

        // The form AppKit trades in is there for a program that wants it.
        XCTAssertNotNil(NSImage(pasteboard: b.pasteboard))
        XCTAssertNotNil(b.pasteboard.data(forType: .tiff))

        // And it is not sent back.
        b.courier.checkPasteboard()
        settle(0.2)
        XCTAssertEqual(keyboard.clip?.origin, 0)
        XCTAssertEqual(keyboard.stored.count, 1)
    }

    func testLongTextIsFetchedOverTheNetwork() {
        let a = computer(0, reachableAt: [loopback])
        let b = computer(1, reachableAt: [loopback])
        let text = String(repeating: "all work and no play makes for a long clip\n", count: 2000)

        copy(text: text, on: a)
        waitFor("the offer") { self.keyboard.clip != nil }
        XCTAssertNotEqual(keyboard.clip!.flags & ClipWire.opaque, 0)

        keyboard.select(1)
        waitFor("the text") { b.pasteboard.string(forType: .string) == text }
    }

    func testSourceConnectsBackWhenItCannotBeReached() {
        // The computer copied on says it is somewhere it is not, as one
        // behind a firewall in effect does; the other can be connected to.
        let a = computer(0, reachableAt: [nowhere])
        let b = computer(1, reachableAt: [loopback])
        let png = noisePNG(side: 300)

        copy(image: png, on: a)
        waitFor("the offer") { self.keyboard.clip != nil }
        let offerCRC = keyboard.clip!.crc

        keyboard.select(1)
        waitFor("the image", timeout: 8) { b.pasteboard.data(forType: .png) == png }
        waitFor("the acknowledgement") { self.keyboard.acks[1] == [offerCRC] }

        XCTAssertEqual(keyboard.relays[0]?.count, 1)
        // Nothing but the offer went through the keyboard.
        XCTAssertEqual(keyboard.stored.count, 1)
        XCTAssertFalse(b.courier.busy)

        // Having answered one request, the source answers the next: this
        // time nobody is waiting to be connected to, so through the keyboard.
        a.courier.receive(keyboard.relays[0]![0])
        waitFor("a second answer", timeout: 15) { self.keyboard.stored.count == 2 }
    }

    func testImageComesThroughTheKeyboardWhenTheNetworkFails() throws {
        let a = computer(0, reachableAt: [nowhere])
        let b = computer(1, reachableAt: [nowhere])
        let png = noisePNG(side: 900)
        XCTAssertGreaterThan(png.count, 1_000_000)

        copy(image: png, on: a)
        waitFor("the offer") { self.keyboard.clip != nil }

        keyboard.select(1)
        waitFor("the image", timeout: 15) { b.pasteboard.data(forType: ClipImage.jpegType) != nil }

        // Scaled down to what the keyboard takes, and still a picture.
        let inline = try XCTUnwrap(keyboard.stored.last)
        XCTAssertEqual(keyboard.stored.count, 2)
        XCTAssertNotEqual(inline.flags & ClipWire.opaque, 0)
        XCTAssertLessThanOrEqual(inline.length, ClipCourier.inlineLimit)
        XCTAssertGreaterThan(inline.length, 2000)
        let jpeg = try XCTUnwrap(b.pasteboard.data(forType: ClipImage.jpegType))
        let image = try XCTUnwrap(NSBitmapImageRep(data: jpeg))
        XCTAssertGreaterThan(image.pixelsWide, 100)
        XCTAssertNotNil(b.pasteboard.data(forType: .png))

        waitFor("the acknowledgement") { self.keyboard.acks[1] == [self.keyboard.clip!.crc] }
        // Worth holding a paste for at first, and not once it turned slow.
        let holds = try XCTUnwrap(keyboard.holds[1])
        XCTAssertEqual(holds.first, ClipWire.holdSoon)
        XCTAssertEqual(holds.last, 0)
        XCTAssertFalse(b.courier.busy)
    }

    func testWantIsRetriedBareWhenItDoesNotFitTheOtherLink() throws {
        let v6 = try XCTUnwrap(ClipAddress([UInt8](repeating: 0xFD, count: 16)))
        // The link to the computer copied on takes 20 bytes a frame, which a
        // WANT naming an IPv6 address is over.
        keyboard.frameCaps[0] = 20
        let a = computer(0, reachableAt: [nowhere])
        let b = computer(1, reachableAt: [v6])

        copy(text: String(repeating: "x", count: 20_000), on: a)
        waitFor("the offer") { self.keyboard.clip != nil }
        keyboard.select(1)

        waitFor("the text", timeout: 15) { b.pasteboard.string(forType: .string)?.count == 20_000 }
        XCTAssertEqual(keyboard.relays[0]?.count, 1)
        XCTAssertEqual(keyboard.relays[0]?.first?.count, 1 + 12)
    }

    func testReceiverGivesUpWhenTheContentCannotBeHad() throws {
        let a = computer(0, reachableAt: [nowhere])
        let b = computer(1, reachableAt: [nowhere])
        // The keyboard would hold this much, but it is more than is worth
        // sending through it, and text cannot be cut down.
        let text = String(repeating: "y", count: 50_000)
        XCTAssertLessThan(text.count, keyboard.maxOpaque)

        copy(text: "what was here before", on: b)
        settle(0.1)
        copy(text: text, on: a)
        waitFor("the offer") { self.keyboard.clip?.origin == 0 }
        let offerCRC = keyboard.clip!.crc

        keyboard.select(1)
        waitFor("word that it is gone", timeout: 8) { self.keyboard.relays[1] != nil }
        waitFor("the receiver to give up") { self.keyboard.acks[1] == [offerCRC] }

        XCTAssertEqual(keyboard.relays[1]?.first, [ClipWire.Frame.relay.rawValue, 2]
                       + (ClipMessage(keyboard.clip!.bytes).flatMap { message -> [UInt8]? in
                           if case .offer(_, let id, _, _, _) = message { return id }
                           return nil
                       } ?? []))
        XCTAssertEqual(try XCTUnwrap(keyboard.holds[1]).last, ClipWire.holdOff)
        XCTAssertEqual(b.pasteboard.string(forType: .string), "what was here before")
        XCTAssertFalse(b.courier.busy)
    }

    func testReceiverGivesUpWhenNobodyIsThere() {
        let a = computer(0, reachableAt: [nowhere])
        copy(image: noisePNG(side: 200), on: a)
        waitFor("the offer") { self.keyboard.clip != nil }
        let offerCRC = keyboard.clip!.crc

        // The computer copied on goes away; its offer is still in the keyboard.
        a.courier.stop()
        a.courier.send = { _ in }
        a.courier.sendClip = { _, _ in }

        let b = computer(1, reachableAt: [nowhere])
        keyboard.select(1)
        waitFor("the receiver to give up", timeout: 12) { self.keyboard.acks[1] == [offerCRC] }
        XCTAssertEqual(keyboard.holds[1]?.last, ClipWire.holdOff)
        XCTAssertFalse(b.courier.busy)
    }

    func testCopyOnTheReceiverAbandonsTheFetch() {
        let a = computer(0, reachableAt: [nowhere])
        let b = computer(1, reachableAt: [nowhere])

        // Nothing will come of this fetch for a while: the content does not
        // fit through the keyboard, and the source is kept from saying so.
        copy(text: String(repeating: "z", count: 100_000), on: a)
        waitFor("the offer") { self.keyboard.clip != nil }
        a.courier.send = { _ in }

        keyboard.select(1)
        waitFor("the fetch to turn slow", timeout: 8) { self.keyboard.holds[1]?.last == 0 }
        XCTAssertTrue(b.courier.busy)

        XCTAssertNotNil(b.channel.expecting)
        copy(text: "typed here instead", on: b)
        XCTAssertNil(b.channel.expecting)
        waitFor("the hold to be let go") { self.keyboard.holds[1]?.last == ClipWire.holdOff }
        waitFor("the new clip") { self.keyboard.clip?.origin == 1 }
        XCTAssertEqual(keyboard.clip?.bytes, Array("typed here instead".utf8))
        XCTAssertFalse(b.courier.busy)
        XCTAssertNil(keyboard.acks[1])

        // No more is said about the old one.
        let holds = keyboard.holds[1]?.count
        settle(1)
        XCTAssertEqual(keyboard.holds[1]?.count, holds)
    }

    /// An OFFER in the keyboard, from profile 0, of a copy that is to be
    /// fetched from `port` on this machine. Returns its id.
    private func offer(at port: UInt16, kind: ClipContent.Kind = .png) -> [UInt8] {
        let id = (0..<8).map { _ in UInt8.random(in: .min ... .max) }
        let message = ClipMessage.offer(kind: kind, id: id, key: vectorKey, port: port,
                                        addresses: [loopback])
        keyboard.hold(message.encoded, flags: ClipWire.opaque, from: 0)
        return id
    }

    private func silent() throws -> SilentListener {
        let listener = try SilentListener()
        waitFor("the silent listener") { listener.port != nil }
        addTeardownBlock { listener.stop() }
        return listener
    }

    func testReceiverGivesUpAtOnceWhenTheKeyboardHasNobodyToAsk() {
        let a = computer(0, reachableAt: [nowhere])
        copy(image: noisePNG(side: 200), on: a)
        waitFor("the offer") { self.keyboard.clip != nil }
        let offerCRC = keyboard.clip!.crc

        // The helper it was copied with has gone, and the keyboard knows.
        a.courier.stop()
        keyboard.detach(0)

        let b = computer(1, reachableAt: [nowhere])
        let started = Date()
        keyboard.select(1)
        waitFor("the receiver to give up") { self.keyboard.acks[1] == [offerCRC] }

        // After asking twice, not after waiting out the slow way.
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(keyboard.holds[1]?.last, ClipWire.holdOff)
        XCTAssertFalse(b.courier.busy)
    }

    func testSourceSaysSoWhenAskedForACopyItNoLongerHas() {
        let a = computer(0, reachableAt: [nowhere])
        copy(image: noisePNG(side: 200), on: a)
        waitFor("the offer") { self.keyboard.clip != nil }
        let offerCRC = keyboard.clip!.crc

        // The app on the first computer is restarted: same profile, a helper
        // that knows nothing of the copy the keyboard still holds.
        a.courier.stop()
        a.channel.stop()
        let again = computer(0, reachableAt: [nowhere])

        let b = computer(1, reachableAt: [nowhere])
        let started = Date()
        keyboard.select(1)
        waitFor("the receiver to give up") { self.keyboard.acks[1] == [offerCRC] }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(keyboard.relays[1]?.first?.prefix(2), [ClipWire.Frame.relay.rawValue, 2])
        XCTAssertFalse(b.courier.busy)
        _ = again
    }

    func testWantIsAnsweredOnce() {
        let a = computer(0, reachableAt: [nowhere])
        let b = computer(1, reachableAt: [nowhere])

        copy(image: noisePNG(side: 900), on: a)
        waitFor("the offer") { self.keyboard.clip != nil }
        keyboard.select(1)
        waitFor("the request", timeout: 8) { self.keyboard.relays[0] != nil }

        // The same request again while the first is still being answered.
        a.courier.receive(keyboard.relays[0]![0])
        a.courier.receive(keyboard.relays[0]![0])
        waitFor("the image", timeout: 15) { b.pasteboard.data(forType: ClipImage.jpegType) != nil }
        settle(1)
        XCTAssertEqual(keyboard.stored.count, 2)

        // Once it has been answered, a later one is answered too.
        a.courier.receive(keyboard.relays[0]![0])
        waitFor("a second answer", timeout: 15) { self.keyboard.stored.count == 3 }
    }

    func testFetchFromASourceThatHangsMovesOn() throws {
        let source = try silent()
        let b = computer(1, reachableAt: [nowhere])
        b.channel.idleTimeout = 0.5
        keyboard.detach(0)

        _ = offer(at: source.port!)
        let offerCRC = keyboard.clip!.crc
        keyboard.select(1)

        // Connected, and then nothing. It is not waited on for ever.
        waitFor("the connection") { source.accepted == 1 }
        XCTAssertTrue(b.courier.busy)
        waitFor("the receiver to give up", timeout: 6) { self.keyboard.acks[1] == [offerCRC] }
        waitFor("the connection to close") { source.closedByPeer == 1 }
        XCTAssertFalse(b.courier.busy)
    }

    func testHoldIsRepeatedForAsLongAsTheFetchRuns() throws {
        let source = try silent()
        let b = computer(1, reachableAt: [nowhere])

        _ = offer(at: source.port!)
        keyboard.select(1)
        waitFor("the connection") { source.accepted == 1 }
        settle(ClipWire.holdRepeat * 4.5)

        let holds = keyboard.holds[1] ?? []
        XCTAssertGreaterThanOrEqual(holds.count, 4)
        // Worth waiting for at first; not once it has gone on this long.
        XCTAssertEqual(holds.first, ClipWire.holdSoon)
        XCTAssertEqual(holds.last, 0)

        // Stopping ends it: no more holds, and the connection is let go.
        b.courier.stop()
        XCTAssertFalse(b.courier.busy)
        XCTAssertNil(b.channel.expecting)
        waitFor("the connection to close") { source.closedByPeer == 1 }
        settle(0.2)
        let count = keyboard.holds[1]?.count
        settle(ClipWire.holdRepeat * 3)
        XCTAssertEqual(keyboard.holds[1]?.count, count)
    }

    func testTextDeliveredMidFetchEndsTheFetch() throws {
        let source = try silent()
        let b = computer(1, reachableAt: [nowhere])

        _ = offer(at: source.port!)
        keyboard.select(1)
        waitFor("the connection") { source.accepted == 1 }
        XCTAssertTrue(b.courier.busy)

        // Something newer is copied on the first computer and handed over.
        let text = Array("newer words".utf8)
        keyboard.hold(text, flags: 0, from: 0)
        waitFor("the text") { b.pasteboard.string(forType: .string) == "newer words" }
        waitFor("its acknowledgement") { self.keyboard.acks[1]?.last == ClipWire.crc32(text) }
        XCTAssertFalse(b.courier.busy)
        waitFor("the connection to close") { source.closedByPeer == 1 }
        settle(0.2)
        let count = keyboard.holds[1]?.count
        settle(ClipWire.holdRepeat * 3)
        XCTAssertEqual(keyboard.holds[1]?.count, count)
    }

    func testGoneForAnotherCopyIsNotThisOnes() {
        let a = computer(0, reachableAt: [nowhere])
        let b = computer(1, reachableAt: [nowhere])

        copy(text: String(repeating: "q", count: 100_000), on: a)
        waitFor("the offer") { self.keyboard.clip != nil }
        // The source is kept from answering, so the fetch stays open.
        a.courier.send = { _ in }
        keyboard.select(1)
        waitFor("the request", timeout: 8) { self.keyboard.relays[0] != nil }

        b.courier.receive(ClipWire.relay(ClipDatagram.gone(id: Array(1...8)).encoded(room: 63))
            .map { $0 })
        settle(0.2)
        XCTAssertTrue(b.courier.busy)
        XCTAssertNil(keyboard.acks[1])
    }

    func testNewCopyWithdrawsWhatWasOnOffer() {
        let a = computer(0, reachableAt: [loopback])
        let b = computer(1, reachableAt: [loopback])
        let png = noisePNG(side: 100)

        copy(image: png, on: a)
        waitFor("the offer") { self.keyboard.clip != nil }
        guard case .offer(_, let id, let key, let port, _)? = ClipMessage(keyboard.clip!.bytes)
        else { return XCTFail("not an offer") }
        XCTAssertNotNil(a.channel.offering)

        copy(text: "something else", on: a)
        XCTAssertNil(a.channel.offering)

        var fetched: Data??
        b.channel.fetch(id: id, key: key, from: [loopback], port: port) { fetched = $0 }
        waitFor("the fetch of the old copy") { fetched != nil }
        XCTAssertEqual(fetched, .some(nil))
    }

    func testClipThatCannotBeReadIsStillAcknowledged() {
        let b = computer(1, reachableAt: [loopback])
        let garbage: [UInt8] = [0x7F, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]

        copy(text: "already here", on: b)
        waitFor("that clip") { self.keyboard.clip?.origin == 1 }

        // From a helper newer than this one, perhaps. A paste here must not
        // be kept waiting on it.
        keyboard.hold(garbage, flags: ClipWire.opaque, from: 0)
        keyboard.select(1)
        waitFor("the acknowledgement") { self.keyboard.acks[1] == [ClipWire.crc32(garbage)] }
        XCTAssertEqual(b.pasteboard.string(forType: .string), "already here")
        XCTAssertFalse(b.courier.busy)
    }

    func testContentThatIsNotWhatItSaysIsNotPlaced() {
        let a = computer(0, reachableAt: [loopback])
        let b = computer(1, reachableAt: [loopback])

        copy(text: "already here", on: b)
        waitFor("that clip") { self.keyboard.clip?.origin == 1 }

        // Fetched over the network, and not an image at all. The keyboard is
        // told there is nothing to wait for; the pasteboard is left alone.
        a.channel.start()
        waitFor("the listener") { a.channel.port != nil }
        let id = Array(1...8).map(UInt8.init)
        a.channel.offering = (id, vectorKey, { Data("not a picture".utf8) })
        let message = ClipMessage.offer(kind: .png, id: id, key: vectorKey, port: a.channel.port!,
                                        addresses: [loopback])
        keyboard.hold(message.encoded, flags: ClipWire.opaque, from: 0)
        keyboard.select(1)
        waitFor("the acknowledgement") { self.keyboard.acks[1] == [self.keyboard.clip!.crc] }
        XCTAssertEqual(keyboard.holds[1]?.last, ClipWire.holdOff)
        XCTAssertEqual(b.pasteboard.string(forType: .string), "already here")
        XCTAssertNil(b.pasteboard.data(forType: .png))
        XCTAssertFalse(b.courier.busy)

        // The same through the keyboard.
        let inline = ClipMessage.inline(kind: .jpeg, id: id, content: [1, 2, 3]).encoded
        keyboard.hold(inline, flags: ClipWire.opaque, from: 0)
        waitFor("its acknowledgement") { self.keyboard.acks[1]?.last == ClipWire.crc32(inline) }
        XCTAssertEqual(b.pasteboard.string(forType: .string), "already here")
    }

    func testCopiesMadeWhileNotRunningAreNotSent() {
        let a = computer(0, reachableAt: [loopback])

        a.courier.stop()
        a.pasteboard.clearContents()
        a.pasteboard.setString("copied while the link was down", forType: .string)
        a.courier.start()
        a.courier.checkPasteboard()
        settle(0.2)
        XCTAssertTrue(keyboard.stored.isEmpty)
        XCTAssertEqual(keyboard.clears, 0)

        copy(text: "copied since", on: a)
        waitFor("the clip") { self.keyboard.clip != nil }
        XCTAssertEqual(keyboard.clip?.bytes, Array("copied since".utf8))
    }

    func testCopyOnTheReceiverCallsOffTheSource() {
        let a = computer(0, reachableAt: [nowhere])
        let b = computer(1, reachableAt: [nowhere])

        copy(image: noisePNG(side: 900), on: a)
        waitFor("the offer") { self.keyboard.clip != nil }
        guard case .offer(_, let id, _, _, _)? = ClipMessage(keyboard.clip!.bytes) else {
            return XCTFail("not an offer")
        }
        keyboard.select(1)
        waitFor("the request", timeout: 8) { self.keyboard.relays[0] != nil }

        // Before the image has started on its way through the keyboard,
        // something is copied on the computer that asked for it.
        copy(text: "typed here instead", on: b)
        waitFor("word to the source") { self.keyboard.relays[0]?.count == 2 }
        XCTAssertEqual(keyboard.relays[0]?.last, [ClipWire.Frame.relay.rawValue, 3] + id)
        waitFor("the new clip") { self.keyboard.clip?.origin == 1 }

        // The source does not go on to send the image, which in the keyboard
        // would replace the newer copy and be handed straight back.
        settle(3)
        XCTAssertEqual(keyboard.clip?.origin, 1)
        XCTAssertEqual(keyboard.stored.count, 2)
        XCTAssertEqual(b.pasteboard.string(forType: .string), "typed here instead")
        XCTAssertNil(a.channel.offering)

        // And if it had been too late to stop, it is not put on the
        // pasteboard over the newer copy.
        let late = ClipMessage.inline(kind: .text, id: id, content: Array("stale".utf8)).encoded
        keyboard.hold(late, flags: ClipWire.opaque, from: 0)
        waitFor("the acknowledgement") { self.keyboard.acks[1] == [ClipWire.crc32(late)] }
        XCTAssertEqual(b.pasteboard.string(forType: .string), "typed here instead")
    }

    func testDeliveryTheKeyboardBreaksOffDoesNotSilenceTheHelper() {
        let b = computer(1, reachableAt: [loopback])

        // BEGIN and some DATA, and then the keyboard is switched away. No END
        // will come. A helper that thought itself busy for ever would never
        // say HELLO again, and never be delivered to again.
        keyboard.deliverPart(Array(String(repeating: "t", count: 500).utf8), to: 1, frames: 3)
        waitFor("the delivery to start") { b.courier.busy }
        settle(0.7)
        XCTAssertFalse(b.courier.busy)
    }

    func testDeliveryDoesNotOverwriteACopyNotYetSeen() {
        let b = computer(1, reachableAt: [loopback])

        // Copied here a moment ago; the pasteboard has not been looked at
        // since. Then a clip from the other computer lands.
        b.pasteboard.clearContents()
        b.pasteboard.setString("fresh local copy", forType: .string)
        keyboard.hold(Array("older, from elsewhere".utf8), flags: 0, from: 0)
        keyboard.select(1)

        waitFor("the local copy to go to the keyboard") { self.keyboard.clip?.origin == 1 }
        XCTAssertEqual(keyboard.clip?.bytes, Array("fresh local copy".utf8))
        XCTAssertEqual(b.pasteboard.string(forType: .string), "fresh local copy")
    }

    func testOlderFirmwareGetsTextOnly() {
        keyboard.version = 1
        let a = computer(0, reachableAt: [loopback])

        copy(image: noisePNG(side: 100), on: a)
        waitFor("the keyboard to be told to drop its clip") { self.keyboard.clears == 1 }
        XCTAssertNil(keyboard.clip)

        copy(text: String(repeating: "w", count: 20_000), on: a)
        waitFor("the same for text it cannot hold") { self.keyboard.clears == 2 }
        XCTAssertTrue(keyboard.stored.isEmpty)

        copy(text: "short", on: a)
        waitFor("the clip") { self.keyboard.clip != nil }
        XCTAssertEqual(keyboard.clip!.flags & ClipWire.opaque, 0)
    }

    func testWhatIsCarriedWhenThereIsBothTextAndAnImage() {
        let a = computer(0, reachableAt: [loopback])
        let png = noisePNG(side: 50)

        // From a document: the words.
        a.pasteboard.clearContents()
        a.pasteboard.setData(png, forType: .png)
        a.pasteboard.setString("cells A1:B2", forType: .string)
        a.courier.checkPasteboard()
        waitFor("the clip") { self.keyboard.clip != nil }
        XCTAssertEqual(keyboard.clip?.bytes, Array("cells A1:B2".utf8))

        // From a browser: the picture, not its address.
        a.pasteboard.clearContents()
        a.pasteboard.setData(png, forType: .png)
        a.pasteboard.setString("https://example.com/cat.png", forType: .string)
        a.pasteboard.setString("https://example.com/cat.png", forType: .URL)
        a.courier.checkPasteboard()
        waitFor("the offer") { self.keyboard.stored.count == 2 }
        XCTAssertNotEqual(keyboard.stored.last!.flags & ClipWire.opaque, 0)

        // A concealed item: nothing, and the keyboard drops what it had.
        a.pasteboard.clearContents()
        a.pasteboard.setString("hunter2", forType: .string)
        a.pasteboard.setString("", forType: .init("org.nspasteboard.ConcealedType"))
        a.courier.checkPasteboard()
        waitFor("the clear") { self.keyboard.clears == 1 }
        XCTAssertNil(keyboard.clip)
    }
}
