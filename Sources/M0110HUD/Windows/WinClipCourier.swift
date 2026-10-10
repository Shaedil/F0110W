import CM0110Win
import Foundation

enum ClipboardRead: Equatable {
    /// Another program held the clipboard open. Try again shortly.
    case busy
    case concealed
    case nothing
    case text([UInt8])
    case png(Data)
}

protocol ClipboardAccess: AnyObject {
    var sequence: UInt32 { get }
    func read() -> ClipboardRead
    func write(text: [UInt8]) -> Bool
    func write(image: Data) -> Bool
}

final class WindowsClipboard: ClipboardAccess {
    var sequence: UInt32 { m0110_clip_sequence() }

    func read() -> ClipboardRead {
        var clip = m0110_clip()
        let kind = m0110_clip_read(&clip)
        defer { m0110_clip_free(&clip) }
        let bytes = clip.data.map { Array(UnsafeBufferPointer(start: $0, count: Int(clip.length))) } ?? []
        switch kind {
        case Int32(M0110_CLIP_BUSY): return .busy
        case Int32(M0110_CLIP_PRIVATE): return .concealed
        case Int32(M0110_CLIP_TEXT): return .text(bytes)
        case Int32(M0110_CLIP_PNG): return .png(Data(bytes))
        default: return .nothing
        }
    }

    func write(text: [UInt8]) -> Bool {
        m0110_clip_write_text(m0110_app_window(), text, UInt32(text.count)) != 0
    }

    func write(image: Data) -> Bool {
        let bytes = [UInt8](image)
        return m0110_clip_write_image(m0110_app_window(), bytes, UInt32(bytes.count)) != 0
    }

    /// Scales and re-encodes as JPEG to fit `budget` bytes, if needed. Same as ClipImage.shrink on the Mac.
    static func shrink(_ content: ClipContent, toFit budget: Int) -> ClipContent? {
        if content.data.count <= budget { return content }
        let bytes = [UInt8](content.data)
        var out: UnsafeMutablePointer<UInt8>?
        var length: UInt32 = 0
        guard m0110_image_shrink(bytes, UInt32(bytes.count), UInt32(max(0, budget)), &out, &length) != 0,
              let out else { return nil }
        defer { m0110_free(out) }
        return ClipContent(kind: .jpeg, data: Data(bytes: out, count: Int(length)))
    }
}

/// Moves clips between this PC's clipboard and the keyboard, like the Mac's ClipCourier
/// minus the network (see helper/PROTOCOL.md). Short text goes into the keyboard. Images
/// and long text go as an OFFER with no address, so the other side asks for them to be
/// sent through the keyboard instead. App thread only.
final class WinClipCourier {
    /// Cap on bytes sent through the keyboard. The link runs a few KB/s, so more is not worth the wait.
    static let inlineLimit = 40_000
    /// Minimum keyboard capacity for an OFFER to fit.
    static let minOpaque = 256
    static let pokeChecks: [TimeInterval] = [0.03, 0.1, 0.25]
    /// Hold and wait times the protocol sets for a helper with no network.
    static let soonFor: TimeInterval = 2.5
    static let inlineWait: TimeInterval = 91.5
    static let deliveryIdle: TimeInterval = 3

    // MARK: Wiring

    var send: (Data) -> Void = { _ in }
    var sendClip: (_ payload: [UInt8], _ flags: UInt8) -> Void = { _, _ in }
    var dropQueuedClip: () -> Void = {}
    var frameCap: () -> Int = { 20 }
    var keyboardIsOnUSB: () -> Bool = { false }
    var schedule: (_ delay: TimeInterval, _ work: @escaping () -> Void) -> UInt32 = { Main.after($0, $1) }
    var cancel: (UInt32) -> Void = { Main.cancel($0) }
    /// Fits an image off the app thread and calls `done` back on it.
    var shrink: (_ content: ClipContent, _ budget: Int, _ done: @escaping (ClipContent?) -> Void) -> Void = {
        content, budget, done in
        DispatchQueue.global(qos: .userInitiated).async {
            let fitted = WindowsClipboard.shrink(content, toFit: budget)
            Main.async { done(fitted) }
        }
    }
    var now: () -> Date = Date.init
    var log: (String) -> Void = { _ in }

    private let clipboard: ClipboardAccess

    // MARK: State

    private(set) var running = false
    private var lastSequence: UInt32
    /// The sequence number from writing a delivered clip, so that clip is not sent straight back.
    private var ownSequence: UInt32?

    /// From the keyboard's STATUS frame.
    private var firmwareVersion: UInt8 = 1
    private var maxLength = 4096
    private var maxOpaque = 0

    private var assembler = ClipAssembler()
    private var deliveryHeard = Date.distantPast

    private struct Offered {
        let id: [UInt8]
        let content: ClipContent
        var answering = false
    }
    private var offered: Offered?

    private final class Fetch {
        let id: [UInt8]
        let offerCRC: UInt32
        var soon = true
        var wantsSent = 0
        var timers: [UInt32] = []
        init(id: [UInt8], offerCRC: UInt32) {
            self.id = id
            self.offerCRC = offerCRC
        }
    }
    private var fetch: Fetch?
    /// ID of a fetch dropped because something was copied here.
    private var abandoned: [UInt8]?

    /// While true, the periodic HELLO waits, since the keyboard reads a HELLO as a fresh helper.
    var busy: Bool {
        fetch != nil || (assembler.active && now().timeIntervalSince(deliveryHeard) < Self.deliveryIdle)
    }

    init(clipboard: ClipboardAccess) {
        self.clipboard = clipboard
        lastSequence = clipboard.sequence
    }

    func start() {
        // Only sync copies made from now on.
        lastSequence = clipboard.sequence
        running = true
    }

    func stop() {
        endFetch()
        running = false
        assembler = ClipAssembler()
    }

    // MARK: - A copy made here

    func checkClipboard() {
        let sequence = clipboard.sequence
        guard sequence != lastSequence else { return }
        guard running, sequence != ownSequence else {
            lastSequence = sequence
            return
        }

        let read = clipboard.read()
        if read == .busy {
            // Busy is different from empty, so check again shortly.
            _ = schedule(0.1) { [weak self] in self?.checkClipboard() }
            return
        }
        // Reading a delayed-render format makes its owner render it, which bumps the
        // sequence number. Re-read it so this read is not taken as a new copy.
        lastSequence = clipboard.sequence

        if let fetch {
            endFetch()
            abandoned = fetch.id
            if fetch.wantsSent > 0 {
                send(ClipWire.relay(ClipDatagram.cancel(id: fetch.id).encoded(room: relayRoom())))
            }
            send(ClipWire.hold(ClipWire.holdOff))
        }
        offered = nil

        switch read {
        case .busy, .nothing:
            dropQueuedClip()
            send(ClipWire.clear)
        case .concealed:
            log("clipboard: skipped a concealed item")
            dropQueuedClip()
            send(ClipWire.clear)
        case .text(let bytes):
            if bytes.count <= maxLength {
                sendClip(bytes, usbFlags())
                log("clipboard: sending \(bytes.count) bytes")
            } else if canOffer {
                offer(ClipContent(kind: .text, data: Data(bytes)))
            } else {
                log("clipboard: skipped \(bytes.count) bytes, over the keyboard's \(maxLength)")
                dropQueuedClip()
                send(ClipWire.clear)
            }
        case .png(let data):
            if canOffer {
                offer(ClipContent(kind: .png, data: data))
            } else {
                log("clipboard: skipped an image; this keyboard's firmware carries text only")
                dropQueuedClip()
                send(ClipWire.clear)
            }
        }
    }

    private var canOffer: Bool { firmwareVersion >= 2 && maxOpaque >= Self.minOpaque }

    private func usbFlags() -> UInt8 {
        ClipWire.usbKnown | (keyboardIsOnUSB() ? ClipWire.usbLocal : 0)
    }

    private static func random(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: .min ... .max) }
    }

    private func offer(_ content: ClipContent) {
        let id = Self.random(ClipMessage.idLength)
        offered = Offered(id: id, content: content)
        let message = ClipMessage.offer(kind: content.kind, id: id, key: Self.random(ClipMessage.keyLength),
                                        port: 0, addresses: [])
        sendClip(message.encoded, ClipWire.opaque | usbFlags())
        log("clipboard: offering \(content.kind == .text ? "long text" : "an image") to the next computer")
    }

    private func answerWant(id: [UInt8]) {
        guard let current = offered, current.id == id else {
            // Something was copied here since.
            send(ClipWire.relay(ClipDatagram.gone(id: id).encoded(room: relayRoom())))
            return
        }
        guard !current.answering else { return }
        offered?.answering = true
        sendInline(current.content, id: id)
    }

    private func sendInline(_ content: ClipContent, id: [UInt8]) {
        let budget = min(maxOpaque, Self.inlineLimit) - ClipMessage.inlineOverhead
        let deliver: (ClipContent?) -> Void = { [weak self] fitted in
            guard let self, self.offered?.id == id else { return }
            self.offered?.answering = false
            guard self.running else { return }
            guard let fitted else {
                self.send(ClipWire.relay(ClipDatagram.gone(id: id).encoded(room: self.relayRoom())))
                self.log("clipboard: too much to send through the keyboard")
                return
            }
            let message = ClipMessage.inline(kind: fitted.kind, id: id, content: Array(fitted.data))
            self.sendClip(message.encoded, ClipWire.opaque | self.usbFlags())
            self.log("clipboard: sending \(fitted.data.count) bytes through the keyboard"
                     + (fitted == content ? "" : ", scaled down to fit"))
        }
        if content.kind == .text {
            deliver(content.data.count <= budget ? content : nil)
        } else {
            shrink(content, budget, deliver)
        }
    }

    private func relayRoom() -> Int {
        min(ClipWire.relayMax, frameCap()) - 1
    }

    // MARK: - Frames from the keyboard

    func receive(_ frame: [UInt8]) {
        guard let first = frame.first, let type = ClipWire.Frame(rawValue: first) else { return }
        switch type {
        case .status:
            guard frame.count >= 4 else { return }
            firmwareVersion = frame[1]
            maxLength = Int(ClipWire.readLE16(frame, at: 2))
            maxOpaque = frame.count >= 6 ? Int(ClipWire.readLE16(frame, at: 4)) : 0
            log("clipboard: keyboard holds up to \(maxLength) bytes of text"
                + (canOffer ? ", and passes on images" : "; its firmware carries text only"))
        case .result:
            guard frame.count >= 2, frame[1] != 0 else { return }
            if frame[1] == ClipWire.resultUnreachable {
                relayWentNowhere()
            } else {
                log("clipboard: keyboard refused the clip (code \(frame[1]))")
            }
        case .poke:
            // The keyboard saw Ctrl+C or Ctrl+X.
            for delay in Self.pokeChecks {
                _ = schedule(delay) { [weak self] in self?.checkClipboard() }
            }
        case .begin:
            assembler.begin(frame)
            deliveryHeard = now()
        case .data:
            assembler.data(frame)
            deliveryHeard = now()
        case .end:
            guard let clip = assembler.end() else {
                log("clipboard: a delivered clip arrived damaged")
                return
            }
            guard running else { return }
            if clip.opaque {
                accept(message: clip.bytes, crc: clip.crc)
            } else {
                accept(text: clip.bytes, crc: clip.crc)
            }
        case .relay:
            guard running, let datagram = ClipDatagram(Array(frame.dropFirst())) else { return }
            switch datagram {
            case .want(let id, _, _):
                answerWant(id: id)
            case .gone(let id):
                if let fetch, fetch.id == id { giveUp(fetch, because: "it is no longer there to be fetched") }
            case .cancel(let id):
                if offered?.id == id { offered = nil }
            }
        default:
            break
        }
    }

    private func accept(text bytes: [UInt8], crc: UInt32) {
        endFetch()
        // If the text cannot go on the clipboard, leave it unacknowledged so the keyboard types it.
        guard place(ClipContent(kind: .text, data: Data(bytes))) == .placed else { return }
        send(ClipWire.ack(crc: crc))
        log("clipboard: took delivery of \(bytes.count) bytes")
    }

    private func accept(message bytes: [UInt8], crc: UInt32) {
        guard let message = ClipMessage(bytes) else {
            endFetch()
            send(ClipWire.ack(crc: crc))
            log("clipboard: the other computer sent something this version cannot read")
            return
        }
        switch message {
        case .offer(_, let id, _, _, _):
            startFetch(Fetch(id: id, offerCRC: crc))
        case .inline(let kind, let id, let content):
            endFetch()
            if id == abandoned {
                send(ClipWire.ack(crc: crc))
                return
            }
            switch place(ClipContent(kind: kind, data: Data(content))) {
            case .placed:
                send(ClipWire.ack(crc: crc))
                log("clipboard: took delivery of \(content.count) bytes through the keyboard")
            case .unusable:
                send(ClipWire.ack(crc: crc))
                log("clipboard: what came through the keyboard could not be put on the clipboard")
            case .superseded:
                break
            }
        }
    }

    // MARK: - Asking for a copy made elsewhere

    private func startFetch(_ new: Fetch) {
        endFetch()
        fetch = new
        hold(new)
        repeatHold(new)
        new.timers.append(schedule(Self.soonFor) { [weak self, weak new] in
            guard let self, let new, self.fetch === new else { return }
            new.soon = false
            self.hold(new)
        })
        new.timers.append(schedule(Self.inlineWait) { [weak self, weak new] in
            guard let self, let new, self.fetch === new else { return }
            self.giveUp(new, because: "nothing came of asking for it")
        })
        sendWant(new)
    }

    private func repeatHold(_ fetch: Fetch) {
        fetch.timers.append(schedule(ClipWire.holdRepeat) { [weak self, weak fetch] in
            guard let self, let fetch, self.fetch === fetch else { return }
            self.hold(fetch)
            self.repeatHold(fetch)
        })
    }

    private func hold(_ fetch: Fetch) {
        send(ClipWire.hold(fetch.soon ? ClipWire.holdSoon : 0))
    }

    private func sendWant(_ fetch: Fetch) {
        fetch.wantsSent += 1
        send(ClipWire.relay(ClipDatagram.want(id: fetch.id, port: 0, addresses: []).encoded(room: relayRoom())))
    }

    /// The keyboard had no helper to pass the WANT to.
    private func relayWentNowhere() {
        guard let fetch, fetch.wantsSent > 0 else { return }
        if fetch.wantsSent == 1 {
            sendWant(fetch)
        } else {
            giveUp(fetch, because: "the computer it was copied on is out of reach")
        }
    }

    /// Tells the keyboard to stop waiting. The HOLD repeats stop first, because the
    /// keyboard would read a HOLD after the ACK as a new request.
    private func giveUp(_ fetch: Fetch, because reason: String) {
        endFetch()
        send(ClipWire.hold(ClipWire.holdOff))
        send(ClipWire.ack(crc: fetch.offerCRC))
        log("clipboard: could not fetch what was copied on the other computer: \(reason)")
    }

    private func endFetch() {
        guard let fetch else { return }
        fetch.timers.forEach(cancel)
        self.fetch = nil
    }

    // MARK: - The clipboard, inbound

    private enum Placed { case placed, superseded, unusable }

    private func place(_ content: ClipContent) -> Placed {
        // A local copy since the last check is newer than this delivery, so do not overwrite it.
        if clipboard.sequence != lastSequence {
            checkClipboard()
            return .superseded
        }
        let written: Bool
        switch content.kind {
        case .text:
            guard String(data: content.data, encoding: .utf8) != nil else { return .unusable }
            written = clipboard.write(text: [UInt8](content.data))
        case .png, .jpeg:
            written = clipboard.write(image: content.data)
        }
        guard written else {
            // Unplaced text is typed by the keyboard instead. Images have no fallback, so ack them anyway.
            return content.kind == .text ? .superseded : .unusable
        }
        ownSequence = clipboard.sequence
        lastSequence = clipboard.sequence
        return .placed
    }
}
