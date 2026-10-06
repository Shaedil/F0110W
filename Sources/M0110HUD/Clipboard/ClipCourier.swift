import AppKit

/// Decides what crosses between this Mac's pasteboard and the keyboard, in
/// both directions. `ClipboardBridge` owns the Bluetooth link and hands this
/// the frames that arrive; this hands back the frames to send.
///
/// Text goes into the keyboard itself. An image, or text longer than the
/// keyboard holds, cannot, so the keyboard carries a short message instead,
/// an OFFER, and the helper on the other computer fetches the content from
/// this one over the network. `helper/PROTOCOL.md` has the whole exchange;
/// the two halves of it here are "A copy made here" and "Fetching".
///
/// ## What is not sent
///
/// Anything a password manager has marked concealed or transient, and
/// anything that is neither text nor an image. The keyboard is then told to
/// drop what it has, so that it never goes on to deliver something older than
/// the most recent copy.
///
/// Runs on the main queue throughout.
final class ClipCourier: NSObject, NSPasteboardItemDataProvider {
    /// How long each stage of a fetch is given. Shortened by the tests.
    struct Timing {
        /// After asking the other helper to connect here instead, how long to
        /// wait for it before settling in for the slow way.
        var putWait: TimeInterval = 1.5
        /// How long to wait for the content to come through the keyboard.
        var inlineWait: TimeInterval = 90
        /// How long a delivery may go without another frame before it is
        /// taken to have been abandoned.
        var deliveryIdle: TimeInterval = 3
    }

    /// Marker types from nspasteboard.org that apps put on the pasteboard to
    /// say "do not record or sync this".
    private static let privateTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
    ]

    /// When to look at the pasteboard after the keyboard says a copy shortcut
    /// was just pressed. The app being copied from needs a moment to act on
    /// it, and how long varies, so there are a few looks rather than one.
    private static let pokeChecks: [TimeInterval] = [0.03, 0.1, 0.25]

    /// The most that is sent through the keyboard when the network fails,
    /// whatever the keyboard has room for. At the few kilobytes a second the
    /// link manages, more than this is a longer wait than it is worth.
    static let inlineLimit = 40_000

    // MARK: Wiring

    /// Queues one frame for the keyboard.
    var send: (Data) -> Void = { _ in }
    /// Queues a clip, in place of any clip still queued.
    var sendClip: (_ payload: [UInt8], _ flags: UInt8) -> Void = { _, _ in }
    /// Drops any clip still queued.
    var dropQueuedClip: () -> Void = {}
    /// The longest frame the link takes in one write.
    var frameCap: () -> Int = { 20 }
    var keyboardIsOnUSB: () -> Bool = { false }
    /// This Mac's addresses, as offered to the other helper.
    var localAddresses: () -> [ClipAddress] = ClipChannel.localAddresses

    private let pasteboard: NSPasteboard
    private let channel: ClipChannel
    private let timing: Timing
    private let log: (String) -> Void

    // MARK: State

    /// The keyboard counts this Mac as having a helper.
    private var running = false
    private var lastChangeCount: Int
    /// The change this made itself when it put a delivered clip on the
    /// pasteboard, so that clip is not sent straight back as a new copy.
    private var ownChangeCount = -1

    /// From the keyboard's STATUS frame.
    private var firmwareVersion: UInt8 = 1
    private var maxLength = 4096
    private var maxOpaque = 0

    private var assembler = ClipAssembler()
    /// When the last frame of a delivery arrived.
    private var deliveryHeard = Date.distantPast

    /// The latest copy made here, if it is one the other helper has to fetch.
    private struct Offered {
        let id: [UInt8]
        let key: [UInt8]
        let kind: ClipContent.Kind
        let produce: () -> ClipContent?
        var content: ClipContent?
        /// A request from the other helper is being answered.
        var answering = false
    }
    private var offered: Offered?

    /// A copy made on another computer that is being fetched.
    private final class Fetch {
        let id: [UInt8]
        let key: [UInt8]
        let kind: ClipContent.Kind
        /// Checksum of the OFFER, which is what the keyboard is told has
        /// been dealt with.
        let offerCRC: UInt32
        /// Whether a paste is worth holding back for it; see `ClipWire.holdSoon`.
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
    /// The copy whose fetch was abandoned because something was copied here
    /// instead. If its content turns up anyway, it is not wanted.
    private var abandoned: [UInt8]?

    /// The image last put on the pasteboard, kept for the forms of it that
    /// are only made if a program asks.
    private var placedImage: Data?

    /// A delivery is arriving or a fetch is running. The periodic HELLO is
    /// held off meanwhile: the keyboard takes one to mean a helper that has
    /// only just started, and would begin the delivery again.
    ///
    /// A delivery only counts while frames keep coming. The keyboard can
    /// abandon one without a word, and a helper that then never said HELLO
    /// again would never be delivered to again.
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

    /// The keyboard has been told a helper is here.
    func start() {
        // Only copies made from here on are carried; whatever is on the
        // pasteboard already was copied before the keyboard was listening.
        lastChangeCount = pasteboard.changeCount
        running = true
        channel.start()
    }

    /// The link is down, or carrying has been switched off. A copy already
    /// offered stays on offer: the keyboard may still be holding its OFFER.
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

        // What was being fetched is no longer the latest copy, and neither is
        // what was on offer.
        if let fetch {
            endFetch()
            abandoned = fetch.id
            if fetch.wantsSent > 0 {
                // The computer it was copied on may be about to send it
                // through the keyboard, which would replace this copy there.
                // Said before the copy itself goes, while the keyboard still
                // knows where to pass it.
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

    /// The least a keyboard must hold for an OFFER with every address to fit.
    static let minOpaque = 256

    /// Whether the keyboard and this helper can pass an OFFER on.
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
        // Only whether there is an image, for now. Reading it makes the
        // program that copied it render it, and for a large one that is not
        // worth doing unless the image is what gets carried.
        let hasImage = ClipImage.isOn(pasteboard)
        // Text wins when there is both: a copy from a document or a
        // spreadsheet means the words. A browser's "Copy Image" is the
        // exception, where the text is only the image's address.
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

        // With no port to be reached at, the other helper still gets to hear
        // of the copy, and asks for it another way.
        let port = channel.port
        let message = ClipMessage.offer(kind: kind, id: new.id, key: new.key, port: port ?? 0,
                                        addresses: port == nil ? [] : localAddresses())
        sendClip(message.encoded, ClipWire.opaque | usbFlags())
        log("clipboard: offering \(kind == .text ? "long text" : "an image") to the next computer")
    }

    /// The content of the copy on offer, made the first time it is wanted.
    private func content(of id: [UInt8]) -> ClipContent? {
        guard let current = offered, current.id == id else { return nil }
        if current.content == nil {
            offered?.content = current.produce()
        }
        return offered?.content
    }

    /// The other helper could not connect here and asks to be connected to,
    /// or failing that to be sent the content through the keyboard.
    private func answerWant(id: [UInt8], port: UInt16, addresses: [ClipAddress]) {
        guard let current = offered, current.id == id else {
            // Something has been copied here since. Saying so spares the
            // other helper a long wait for content that is not coming.
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

        // With no addresses to try, this fails at once and falls through to
        // the keyboard.
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

    /// Sends the content through the keyboard, cut down to what that takes.
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
                // The link went while this was being made ready.
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
            // The keyboard saw Cmd-C or Cmd-X go by. Looking now, rather than
            // on the next tick, is what lets a quick switch-and-paste carry
            // the new clip instead of the one before it.
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
        // A different clip from the one being fetched, if one was.
        endFetch()

        // Text that cannot be put on the pasteboard is left unacknowledged:
        // the keyboard then types it, which is the next best thing.
        guard place(ClipContent(kind: .text, data: Data(bytes))) == .placed else { return }
        // The acknowledgement is what tells the keyboard to let the paste
        // through instead of typing the clip.
        send(ClipWire.ack(crc: crc))
        log("clipboard: took delivery of \(bytes.count) bytes")
    }

    private func accept(message bytes: [UInt8], crc: UInt32) {
        guard let message = ClipMessage(bytes) else {
            // From a newer helper than this one. Acknowledged all the same,
            // so that a paste here is not kept waiting on it.
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
                // Asked for before something was copied here instead. The
                // acknowledgement still goes, so a paste is not held for it.
                send(ClipWire.ack(crc: crc))
                return
            }
            switch place(ClipContent(kind: kind, data: Data(content))) {
            case .placed:
                send(ClipWire.ack(crc: crc))
                log("clipboard: took delivery of \(content.count) bytes through the keyboard")
            case .unusable:
                // Nothing more will come of it; a paste should not wait.
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

        // Said at once and then repeated, so that a paste pressed while this
        // is going on waits for it instead of putting down whatever the
        // pasteboard held before.
        hold(new)
        after(ClipWire.holdRepeat, repeats: true, during: new) { [weak self] fetch in
            self?.hold(fetch)
        }
        // If it has not come by the time both ways over the network have had
        // their chance, it is coming the slow way or as a long download, and
        // a paste is not worth holding for either.
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

    /// Nothing answered at any address the copy was offered at. The computer
    /// it was made on may still be able to connect here, and if not, it can
    /// send the content through the keyboard.
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
            // It may only have been too long for the link at the other end.
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
            // The same as giving up: the keyboard is told not to wait.
            send(ClipWire.hold(ClipWire.holdOff))
            send(ClipWire.ack(crc: fetch.offerCRC))
            log("clipboard: what was fetched could not be put on the pasteboard")
        case .superseded:
            break
        }
    }

    /// Tells the keyboard there is nothing more to wait for, which lets a
    /// paste through as this Mac's own.
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

    /// Runs `action` after `interval`, for as long as `fetch` is the one in
    /// progress.
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
        /// Something was copied here in the meantime, and stays.
        case superseded
        /// The content is not what it says it is.
        case unusable
    }

    /// Puts delivered content on the pasteboard.
    private func place(_ content: ClipContent) -> Placed {
        // Something copied here since the last look is newer than whatever
        // has just arrived, and must not be written over.
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
            // TIFF is what AppKit itself trades in, and some programs take
            // nothing else. It is several times the size, so it is made only
            // for a program that asks.
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
