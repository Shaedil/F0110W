import AppKit

/// Moves copies between this Mac's pasteboard and the keyboard, both ways.
/// Text goes into the keyboard itself. Images and text too long for it go as
/// an OFFER, and the other computer's helper fetches the content over the
/// network (see `helper/PROTOCOL.md`). Concealed or transient items (password
/// managers) are never sent, and the keyboard is told to drop its old clip
/// so it never delivers an outdated copy. Runs on the main queue.
final class ClipCourier: NSObject, NSPasteboardItemDataProvider {
    /// Fetch timeouts, shortened by the tests.
    struct Timing {
        /// How long to wait for the other helper to connect here after asking it to.
        var putWait: TimeInterval = 1.5
        var inlineWait: TimeInterval = 90
        /// A delivery with no new frame for this long counts as abandoned.
        var deliveryIdle: TimeInterval = 3
    }

    /// nspasteboard.org markers that apps set to mean "do not record or sync this".
    private static let privateTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
    ]

    /// Check times after a copy shortcut. Apps take varying time to update the pasteboard.
    private static let pokeChecks: [TimeInterval] = [0.03, 0.1, 0.25]

    /// Cap on what is sent through the keyboard when the network fails. The
    /// link only does a few KB/s, so more than this takes too long.
    static let inlineLimit = 40_000

    // MARK: Wiring

    var send: (Data) -> Void = { _ in }
    /// Queues a clip, replacing any clip still queued.
    var sendClip: (_ payload: [UInt8], _ flags: UInt8) -> Void = { _, _ in }
    var dropQueuedClip: () -> Void = {}
    var frameCap: () -> Int = { 20 }
    var keyboardIsOnUSB: () -> Bool = { false }
    var localAddresses: () -> [ClipAddress] = ClipChannel.localAddresses

    private let pasteboard: NSPasteboard
    private let channel: ClipChannel
    private let timing: Timing
    private let log: (String) -> Void

    // MARK: State

    private var running = false
    private var lastChangeCount: Int
    /// Change count from placing a delivered clip, so it is not sent back as a new copy.
    private var ownChangeCount = -1

    /// From the keyboard's STATUS frame.
    private var firmwareVersion: UInt8 = 1
    private var maxLength = 4096
    private var maxOpaque = 0

    private var assembler = ClipAssembler()
    private var deliveryHeard = Date.distantPast

    /// The latest local copy, when it is one the other helper has to fetch.
    private struct Offered {
        let id: [UInt8]
        let key: [UInt8]
        let kind: ClipContent.Kind
        let produce: () -> ClipContent?
        var content: ClipContent?
        var answering = false
    }
    private var offered: Offered?

    private final class Fetch {
        let id: [UInt8]
        let key: [UInt8]
        let kind: ClipContent.Kind
        /// CRC of the OFFER. This is what gets acked to the keyboard.
        let offerCRC: UInt32
        /// Whether a paste is worth holding for it. See `ClipWire.holdSoon`.
        var soon = true
        var wantsSent = 0
        var timers: [Timer] = []
        var callOff: () -> Void = {}

        init(id: [UInt8], key: [UInt8], kind: ClipContent.Kind, offerCRC: UInt32) {
            self.id = id
            self.key = key
            self.kind = kind
            self.offerCRC = offerCRC
        }
    }
    private var fetch: Fetch?
    /// A fetch dropped for a newer local copy. Its content is ignored if it still arrives.
    private var abandoned: [UInt8]?

    private var placedImage: Data?

    /// True during a delivery or fetch, when the periodic HELLO must wait (the
    /// keyboard restarts a delivery on HELLO). A delivery only counts while
    /// frames keep coming, since the keyboard can drop one without notice.
    var busy: Bool {
        fetch != nil
            || (assembler.active && Date().timeIntervalSince(deliveryHeard) < timing.deliveryIdle)
    }

    init(pasteboard: NSPasteboard = .general, channel: ClipChannel, timing: Timing = Timing(),
         log: @escaping (String) -> Void = { _ in }) {
        self.pasteboard = pasteboard
        self.channel = channel
        self.timing = timing
        self.log = log
        lastChangeCount = pasteboard.changeCount
        super.init()
    }

    func start() {
        // Skip whatever is already on the pasteboard. Only new copies are sent.
        lastChangeCount = pasteboard.changeCount
        running = true
        channel.start()
    }

    /// The offer stays, since the keyboard may still hold its OFFER.
    func stop() {
        endFetch()
        running = false
        assembler = ClipAssembler()
    }

    // MARK: - A copy made here

    func checkPasteboard() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        guard running, count != ownChangeCount else { return }

        if let fetch {
            endFetch()
            abandoned = fetch.id
            if fetch.wantsSent > 0 {
                // The other computer may be about to send it through the keyboard.
                // Cancel first, while the keyboard still knows where to route it.
                send(ClipWire.relay(ClipDatagram.cancel(id: fetch.id).encoded(room: relayRoom())))
            }
            send(ClipWire.hold(ClipWire.holdOff))
        }
        offered = nil
        channel.offering = nil

        switch carried() {
        case .nothing:
            dropQueuedClip()
            send(ClipWire.clear)
        case .text(let bytes):
            sendClip(bytes, usbFlags())
            log("clipboard: sending \(bytes.count) bytes")
        case .offer(let kind, let produce):
            offer(kind: kind, produce: produce)
        }
    }

    private enum Carried {
        case nothing
        case text([UInt8])
        case offer(ClipContent.Kind, () -> ClipContent?)
    }

    /// Smallest keyboard buffer that fits an OFFER with every address.
    static let minOpaque = 256

    private var canOffer: Bool {
        firmwareVersion >= 2 && maxOpaque >= Self.minOpaque
    }

    private func carried() -> Carried {
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: Self.privateTypes) else {
            log("clipboard: skipped a concealed item")
            return .nothing
        }

        let text = pasteboard.string(forType: .string).flatMap { $0.isEmpty ? nil : $0 }
        // Reading an image makes the source app render it, so only check for one here.
        let hasImage = ClipImage.isOn(pasteboard)
        // Text wins when both are there, since a copy from a document means the
        // words. A browser's "Copy Image" is the exception: its text is just the URL.
        let textIsOnlyALink = types.contains("public.url") && !types.contains("public.file-url")

        if hasImage, canOffer, text == nil || textIsOnlyALink,
           let image = ClipImage.read(pasteboard) {
            return .offer(image.kind, image.content)
        }

        if let text {
            let bytes = Array(text.replacingOccurrences(of: "\r\n", with: "\n").utf8)
            if bytes.count <= maxLength { return .text(bytes) }
            if canOffer {
                return .offer(.text, { ClipContent(kind: .text, data: Data(bytes)) })
            }
            log("clipboard: skipped \(bytes.count) bytes, over the keyboard's \(maxLength)")
            return .nothing
        }

        if hasImage {
            log("clipboard: skipped an image; this keyboard's firmware carries text only")
        }
        return .nothing
    }

    private func usbFlags() -> UInt8 {
        ClipWire.usbKnown | (keyboardIsOnUSB() ? ClipWire.usbLocal : 0)
    }

    private static func random(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: .min ... .max) }
    }

    private func offer(kind: ClipContent.Kind, produce: @escaping () -> ClipContent?) {
        let new = Offered(id: Self.random(ClipMessage.idLength),
                          key: Self.random(ClipMessage.keyLength), kind: kind, produce: produce)
        let id = new.id

        offered = new
        channel.offering = (new.id, new.key, { [weak self] in self?.content(of: id)?.data })

        // Without a port the other helper still hears of the copy and asks another way.
        let port = channel.port
        let message = ClipMessage.offer(kind: kind, id: new.id, key: new.key, port: port ?? 0,
                                        addresses: port == nil ? [] : localAddresses())
        sendClip(message.encoded, ClipWire.opaque | usbFlags())
        log("clipboard: offering \(kind == .text ? "long text" : "an image") to the next computer")
    }

    /// Content of the offered copy, produced the first time it is needed.
    private func content(of id: [UInt8]) -> ClipContent? {
        guard let current = offered, current.id == id else { return nil }
        if current.content == nil {
            offered?.content = current.produce()
        }
        return offered?.content
    }

    /// The other helper could not connect here. It asks this side to connect
    /// to it, or else to send the content through the keyboard.
    private func answerWant(id: [UInt8], port: UInt16, addresses: [ClipAddress]) {
        guard let current = offered, current.id == id else {
            // Something was copied here since. Saying so saves the other helper a long wait.
            send(ClipWire.relay(ClipDatagram.gone(id: id).encoded(room: relayRoom())))
            return
        }
        guard !current.answering else { return }
        offered?.answering = true

        guard let content = content(of: id) else {
            offered?.answering = false
            send(ClipWire.relay(ClipDatagram.gone(id: id).encoded(room: relayRoom())))
            return
        }

        // With no addresses this fails at once and falls back to the keyboard.
        channel.push(id: id, key: current.key, content: content.data, to: addresses, port: port) {
            [weak self] handedOver in
            guard let self, self.running, self.offered?.id == id else { return }
            if handedOver {
                self.offered?.answering = false
                self.log("clipboard: handed over \(content.data.count) bytes over the network")
            } else {
                self.sendInline(content, id: id)
            }
        }
    }

    private func sendInline(_ content: ClipContent, id: [UInt8]) {
        let budget = min(maxOpaque, Self.inlineLimit) - ClipMessage.inlineOverhead

        DispatchQueue.global(qos: .userInitiated).async {
            let fitted: ClipContent?
            if content.kind == .text {
                fitted = content.data.count <= budget ? content : nil
            } else {
                fitted = ClipImage.shrink(content, toFit: budget)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.offered?.id == id else { return }
                self.offered?.answering = false
                guard self.running else { return }

                guard let fitted else {
                    self.send(ClipWire.relay(
                        ClipDatagram.gone(id: id).encoded(room: self.relayRoom())))
                    self.log("clipboard: too much to send through the keyboard, "
                             + "and the other computer cannot be reached over the network")
                    return
                }

                let message = ClipMessage.inline(kind: fitted.kind, id: id,
                                                 content: Array(fitted.data))
                self.sendClip(message.encoded, ClipWire.opaque | self.usbFlags())
                self.log("clipboard: sending \(fitted.data.count) bytes through the keyboard"
                         + (fitted == content ? "" : ", scaled down to fit"))
            }
        }
    }

    /// Room for a datagram in one RELAY frame on this link.
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
            // The keyboard saw Cmd-C or Cmd-X. Checking now lets a quick
            // switch-and-paste get the new clip.
            for delay in Self.pokeChecks {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.checkPasteboard()
                }
            }
        case .begin:
            assembler.begin(frame)
            deliveryHeard = Date()
        case .data:
            assembler.data(frame)
            deliveryHeard = Date()
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
            case let .want(id, port, addresses):
                answerWant(id: id, port: port, addresses: addresses)
            case let .gone(id):
                if let fetch, fetch.id == id {
                    giveUp(fetch, because: "it is no longer there to be fetched")
                }
            case let .cancel(id):
                // Something newer was copied on the computer that asked.
                if offered?.id == id {
                    offered = nil
                    channel.offering = nil
                }
            }
        default:
            break
        }
    }

    private func accept(text bytes: [UInt8], crc: UInt32) {
        endFetch()

        // The ack tells the keyboard to let the paste through. Without it the
        // keyboard types the clip, which is the fallback if placing fails.
        guard place(ClipContent(kind: .text, data: Data(bytes))) == .placed else { return }
        send(ClipWire.ack(crc: crc))
        log("clipboard: took delivery of \(bytes.count) bytes")
    }

    private func accept(message bytes: [UInt8], crc: UInt32) {
        guard let message = ClipMessage(bytes) else {
            // This came from a newer helper. Ack it anyway so a paste here does not wait.
            endFetch()
            send(ClipWire.ack(crc: crc))
            log("clipboard: the other computer sent something this version cannot read")
            return
        }

        switch message {
        case let .offer(kind, id, key, port, addresses):
            startFetch(Fetch(id: id, key: key, kind: kind, offerCRC: crc),
                       port: port, addresses: addresses)
        case let .inline(kind, id, content):
            endFetch()
            if id == abandoned {
                // This was requested before a local copy replaced it. Ack it so a paste does not wait.
                send(ClipWire.ack(crc: crc))
                return
            }
            switch place(ClipContent(kind: kind, data: Data(content))) {
            case .placed:
                send(ClipWire.ack(crc: crc))
                log("clipboard: took delivery of \(content.count) bytes through the keyboard")
            case .unusable:
                send(ClipWire.ack(crc: crc))
                log("clipboard: what came through the keyboard could not be put on the pasteboard")
            case .superseded:
                break
            }
        }
    }

    // MARK: - Fetching

    private func startFetch(_ new: Fetch, port: UInt16, addresses: [ClipAddress]) {
        endFetch()
        fetch = new

        // Sent now and repeated, so a paste meanwhile waits for this copy instead of the old one.
        hold(new)
        after(ClipWire.holdRepeat, repeats: true, during: new) { [weak self] fetch in
            self?.hold(fetch)
        }
        // After both network routes had their chance, it is coming through the
        // keyboard or as a long download, so a paste should not wait for it.
        after(ClipChannel.connectTimeout + timing.putWait, repeats: false, during: new) {
            [weak self] fetch in
            fetch.soon = false
            self?.hold(fetch)
        }

        new.callOff = channel.fetch(id: new.id, key: new.key, from: addresses, port: port) {
            [weak self, weak new] data in
            guard let self, let new, self.fetch === new else { return }
            if let data {
                self.finish(new, ClipContent(kind: new.kind, data: data))
            } else {
                self.askToBeSent(new)
            }
        }
    }

    private func hold(_ fetch: Fetch) {
        send(ClipWire.hold(fetch.soon ? ClipWire.holdSoon : 0))
    }

    /// No address answered. The other side may still connect here or use the keyboard.
    private func askToBeSent(_ fetch: Fetch) {
        channel.expecting = (fetch.id, fetch.key, { [weak self, weak fetch] data in
            guard let self, let fetch, self.fetch === fetch else { return }
            self.finish(fetch, ClipContent(kind: fetch.kind, data: data))
        })
        sendWant(fetch, withAddresses: true)

        after(timing.putWait + timing.inlineWait, repeats: false, during: fetch) {
            [weak self] fetch in
            self?.giveUp(fetch, because: "nothing came of asking for it")
        }
    }

    private func sendWant(_ fetch: Fetch, withAddresses: Bool) {
        let port = channel.port
        let datagram = ClipDatagram.want(
            id: fetch.id, port: port ?? 0,
            addresses: withAddresses && port != nil ? localAddresses() : [])

        fetch.wantsSent += 1
        send(ClipWire.relay(datagram.encoded(room: relayRoom())))
    }

    /// The keyboard had no helper to pass the last RELAY to.
    private func relayWentNowhere() {
        guard let fetch, fetch.wantsSent > 0 else { return }

        if fetch.wantsSent == 1 {
            // The WANT may have been too long for the other link. Retry without addresses.
            sendWant(fetch, withAddresses: false)
        } else {
            giveUp(fetch, because: "the computer it was copied on is out of reach")
        }
    }

    private func finish(_ fetch: Fetch, _ content: ClipContent) {
        endFetch()
        switch place(content) {
        case .placed:
            send(ClipWire.ack(crc: fetch.offerCRC))
            log("clipboard: fetched \(content.data.count) bytes over the network")
        case .unusable:
            // Same as giving up, so the keyboard stops waiting.
            send(ClipWire.hold(ClipWire.holdOff))
            send(ClipWire.ack(crc: fetch.offerCRC))
            log("clipboard: what was fetched could not be put on the pasteboard")
        case .superseded:
            break
        }
    }

    /// Tells the keyboard to stop waiting, so a paste uses this Mac's own clipboard.
    private func giveUp(_ fetch: Fetch, because reason: String) {
        endFetch()
        send(ClipWire.hold(ClipWire.holdOff))
        send(ClipWire.ack(crc: fetch.offerCRC))
        log("clipboard: could not fetch what was copied on the other computer: \(reason)")
    }

    private func endFetch() {
        guard let fetch else { return }
        fetch.timers.forEach { $0.invalidate() }
        fetch.callOff()
        if channel.expecting?.id == fetch.id {
            channel.expecting = nil
        }
        self.fetch = nil
    }

    /// Runs `action` after `interval`, as long as `fetch` is still the current one.
    private func after(_ interval: TimeInterval, repeats: Bool, during fetch: Fetch,
                       _ action: @escaping (Fetch) -> Void) {
        let timer = Timer(timeInterval: interval, repeats: repeats) { [weak self, weak fetch] _ in
            guard let self, let fetch, self.fetch === fetch else { return }
            action(fetch)
        }
        RunLoop.main.add(timer, forMode: .common)
        fetch.timers.append(timer)
    }

    // MARK: - The pasteboard, inbound

    private enum Placed {
        case placed
        case superseded
        /// The content does not match its stated kind.
        case unusable
    }

    private func place(_ content: ClipContent) -> Placed {
        // Something copied here since the last check is newer, so keep it.
        if pasteboard.changeCount != lastChangeCount {
            checkPasteboard()
            return .superseded
        }

        switch content.kind {
        case .text:
            guard let text = String(data: content.data, encoding: .utf8) else { return .unusable }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)

        case .png, .jpeg:
            guard NSBitmapImageRep(data: content.data) != nil else { return .unusable }
            let item = NSPasteboardItem()
            let png = content.kind == .png

            item.setData(content.data, forType: png ? .png : ClipImage.jpegType)
            // Some apps only take TIFF, which is much larger, so it is made on request.
            item.setDataProvider(self, forTypes: png ? [.tiff] : [.png, .tiff])
            pasteboard.clearContents()
            placedImage = content.data
            pasteboard.writeObjects([item])
        }

        ownChangeCount = pasteboard.changeCount
        lastChangeCount = ownChangeCount
        return .placed
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        guard let placedImage,
              let data = ClipImage.convert(placedImage, to: type == .png ? .png : .tiff)
        else { return }
        item.setData(data, forType: type)
    }
}
