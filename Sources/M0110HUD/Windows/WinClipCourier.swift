import CM0110Win
import Foundation

/// What is on the clipboard, as the courier needs it.
enum ClipboardRead: Equatable {
    /// Another program held the clipboard throughout: try again shortly.
    case busy
    /// A password manager marked it not to be recorded or synced.
    case concealed
    case nothing
    /// UTF-8 with LF line endings.
    case text([UInt8])
    case png(Data)
}

/// The Windows clipboard, behind a protocol so the tests can stand in for it.
protocol ClipboardAccess: AnyObject {
    /// Moves on whenever anything is put on the clipboard.
    var sequence: UInt32 { get }
    func read() -> ClipboardRead
    func write(text: [UInt8]) -> Bool
    func write(image: Data) -> Bool
}

/// The real one, through CM0110Win.
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

    /// `content` made to fit in `budget` bytes, scaled and re-encoded as JPEG
    /// if it does not already: ClipImage.shrink on the Mac.
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

/// Decides what crosses between this PC's clipboard and the keyboard, in
/// both directions: the Mac's ClipCourier, and `helper/PROTOCOL.md`'s
/// receiver and source, without the network.
///
/// Text goes into the keyboard itself. An image, or text longer than the
/// keyboard holds, goes as an OFFER with nowhere to fetch it from, and the
/// other helper then asks for it to be sent through the keyboard instead: the
/// fallback the protocol has for helpers that cannot reach each other. The
/// same in reverse for a copy made on the other computer.
///
/// Runs on the app thread throughout.
final class WinClipCourier {
    /// The most sent through the keyboard, whatever it has room for: at the
    /// few kilobytes a second the link manages, more is not worth the wait.
    static let inlineLimit = 40_000
    /// The least a keyboard must hold for an OFFER to fit.
    static let minOpaque = 256
    /// When to look at the clipboard after the keyboard saw a copy shortcut.
    static let pokeChecks: [TimeInterval] = [0.03, 0.1, 0.25]
    /// How long a paste is held for a fetch, and how long the content is
    /// waited for, as the protocol sets them for a helper with no network.
    static let soonFor: TimeInterval = 2.5
    static let inlineWait: TimeInterval = 91.5
    static let deliveryIdle: TimeInterval = 3

    // MARK: Wiring

    /// Queues one frame for the keyboard.
    var send: (Data) -> Void = { _ in }
    /// Queues a clip, in place of any clip still queued.
    var sendClip: (_ payload: [UInt8], _ flags: UInt8) -> Void = { _, _ in }
    var dropQueuedClip: () -> Void = {}
    /// The longest frame the link takes in one write.
    var frameCap: () -> Int = { 20 }
    var keyboardIsOnUSB: () -> Bool = { false }
    /// Runs `work` after `delay` on the app thread; returns a token for
    /// `cancel`. The tests run a clock of their own.
    var schedule: (_ delay: TimeInterval, _ work: @escaping () -> Void) -> UInt32 = { Main.after($0, $1) }
    var cancel: (UInt32) -> Void = { Main.cancel($0) }
    /// Makes an image fit the keyboard, off the app thread, and hands the
    /// result back on it.
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
    /// The change this made itself when it put a delivered clip on the
    /// clipboard, so that clip is not sent straight back as a new copy.
    private var ownSequence: UInt32?

    /// From the keyboard's STATUS frame.
    private var firmwareVersion: UInt8 = 1
    private var maxLength = 4096
    private var maxOpaque = 0

    private var assembler = ClipAssembler()
    private var deliveryHeard = Date.distantPast

    /// The latest copy made here, if it has to be asked for.
    private struct Offered {
        let id: [UInt8]
        let content: ClipContent
        var answering = false
    }
    private var offered: Offered?

    /// A copy made on another computer, being asked for.
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
    /// The copy whose fetch was abandoned because something was copied here.
    private var abandoned: [UInt8]?

    /// A delivery is arriving or a fetch is running: the periodic HELLO waits,
    /// since the keyboard takes one to mean a helper that has just started.
    var busy: Bool {
        fetch != nil || (assembler.active && now().timeIntervalSince(deliveryHeard) < Self.deliveryIdle)
    }

    init(clipboard: ClipboardAccess) {
        self.clipboard = clipboard
        lastSequence = clipboard.sequence
    }

    /// The keyboard has been told a helper is here.
    func start() {
        // Only copies made from here on are carried.
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
            // Not the same as nothing being there: look again shortly.
            _ = schedule(0.1) { [weak self] in self?.checkClipboard() }
            return
        }
        // Reading a format its owner had only promised makes the owner render
        // it, and that moves the number on: taken again, so the reading is not
        // mistaken for another copy.
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

    /// An OFFER with no port and no addresses: the other helper cannot fetch
    /// it, and asks for it through the keyboard instead.
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
            // Something has been copied here since.
            send(ClipWire.relay(ClipDatagram.gone(id: id).encoded(room: relayRoom())))
            return
        }
        guard !current.answering else { return }
        offered?.answering = true
        sendInline(current.content, id: id)
    }

    /// Sends the content through the keyboard, cut down to what that takes.
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
            // The keyboard saw Ctrl-C or Ctrl-X go by.
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
        // Text that cannot be put on the clipboard is left unacknowledged:
        // the keyboard then types it, which is the next best thing.
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

    /// There is no network to fetch over, so the copy is asked for through the
    /// keyboard at once, and pastes are held meanwhile.
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

    /// Tells the keyboard there is nothing more to wait for. The HOLD repeats
    /// stop first: the keyboard would take one after the ACK as a new request.
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
        // Something copied here since the last look is newer than whatever
        // has just arrived, and must not be written over.
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
            // Text left unplaced is typed by the keyboard instead; an image
            // has no such fallback and is acknowledged all the same.
            return content.kind == .text ? .superseded : .unusable
        }
        ownSequence = clipboard.sequence
        lastSequence = clipboard.sequence
        return .placed
    }
}
