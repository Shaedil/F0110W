import CM0110Win
import Foundation

/// GATT link to the keyboard's clipboard service, like the Mac's ClipboardBridge. Frame
/// contents belong to WinClipCourier. GATT calls block, so they run one at a time on
/// their own queue. Everything else is on the app thread.
final class WinClipLink {
    /// Must match `CLIP_UUID` in the firmware's `config/clipboard/clipboard.c`.
    static let service = gattUUID("B02961DE-EEC8-443B-9EDE-2919A6354188")
    static let rx = gattUUID("B02961DF-EEC8-443B-9EDE-2919A6354188")
    static let tx = gattUUID("B02961E0-EEC8-443B-9EDE-2919A6354188")

    private static let usbVendor: UInt16 = 0x1D50
    private static let usbProduct: UInt16 = 0x615E

    private static let tickInterval: TimeInterval = 2
    /// The firmware stops waiting on a helper that misses an ack, and a HELLO makes it trusted again.
    private static let helloEveryTicks = 15
    /// Win32 does not report the link MTU, so try each size and step down when a write fails.
    private static let frameSizes = [244, 182, 128, 64, 20]

    let courier: WinClipCourier
    private let deviceName: String
    private let log: (String) -> Void

    /// Turning it off sends BYE, so the keyboard types pastes here instead of waiting on this helper.
    var enabled: Bool {
        didSet { if enabled != oldValue { tick() } }
    }

    // App thread only.
    private var instance: String?
    private var opening = false
    private var open = false
    private var announced = false
    /// No usable clipboard service (older firmware). Retried only after a reconnect, which a reflash forces.
    private var unsupported = false
    private var retryAfter = Date.distantPast
    private var outbox = ClipOutbox()
    /// Kept so the clip can be rewritten at a smaller frame size.
    private var clip: (payload: [UInt8], flags: UInt8)?
    private var writing = false
    private var failures = 0
    private var frameSize = 0
    private var ticksSinceHello = 0
    private var lastLogged = ""

    // Queue only.
    private let queue = DispatchQueue(label: "M0110HUD.clipboard")
    private var rxLink: OpaquePointer?
    private var txLink: OpaquePointer?

    init(courier: WinClipCourier, deviceName: String, enabled: Bool, log: @escaping (String) -> Void) {
        self.courier = courier
        self.deviceName = deviceName
        self.enabled = enabled
        self.log = log
        courier.send = { [weak self] frame in self?.send(frame) }
        courier.sendClip = { [weak self] payload, flags in self?.sendClip(payload, flags: flags) }
        courier.dropQueuedClip = { [weak self] in
            self?.outbox.dropClip()
            self?.clip = nil
        }
        courier.frameCap = { [weak self] in self.map { Self.frameSizes[$0.frameSize] } ?? 20 }
        courier.keyboardIsOnUSB = { [weak self] in
            guard let self else { return false }
            return m0110_usb_present(Self.usbVendor, Self.usbProduct, self.deviceName.wide) != 0
        }
        courier.log = log
        scheduleTick()
    }

    private func scheduleTick() {
        Main.after(Self.tickInterval) { [weak self] in
            self?.tick()
            self?.scheduleTick()
        }
    }

    private func logOnce(_ message: String) {
        guard message != lastLogged else { return }
        lastLogged = message
        log(message)
    }

    // MARK: The keyboard coming and going

    func keyboard(_ found: String?) {
        if found == nil {
            drop()
            // It may come back with new firmware.
            unsupported = false
            retryAfter = .distantPast
        }
        instance = found
        tick()
    }

    private func tick() {
        ticksSinceHello += 1
        if !enabled, announced {
            log("clipboard: switched off")
            goodbye()
        }
        if enabled, open, !announced {
            announce()
        } else if announced, ticksSinceHello >= Self.helloEveryTicks, !courier.busy {
            ticksSinceHello = 0
            send(ClipWire.hello)
        }
        if enabled, !open, !opening, !unsupported, let instance, Date() >= retryAfter {
            openLink(instance)
        }
        pump()
    }

    private func openLink(_ instance: String) {
        opening = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        queue.async { [self] in
            var error: Int32 = 0
            guard let rx = m0110_gatt_open(instance.wide, Self.service, Self.rx, &error),
                  let tx = m0110_gatt_open(instance.wide, Self.service, Self.tx, &error) else {
                closeLinks()
                Main.async { [self] in failed("the keyboard's firmware has no clipboard service", error) }
                return
            }
            rxLink = rx
            txLink = tx
            let subscribed = m0110_gatt_subscribe(tx, { context, data, length in
                guard let context, let data else { return }
                let frame = Array(UnsafeBufferPointer(start: data, count: Int(length)))
                let link = Unmanaged<WinClipLink>.fromOpaque(context).takeUnretainedValue()
                Main.async { link.received(frame) }
            }, context)
            guard subscribed == 0 else {
                closeLinks()
                // The service needs encryption, so a connected but unpaired keyboard fails here.
                Main.async { [self] in failed("could not subscribe", subscribed) }
                return
            }
            Main.async { [self] in
                opening = false
                open = true
                frameSize = 0
                failures = 0
                log("clipboard: linked")
                if enabled { announce() }
            }
        }
    }

    private func failed(_ what: String, _ error: Int32) {
        opening = false
        unsupported = true
        logOnce("clipboard: \(what) (\(hex(error)))")
    }

    /// Queue only.
    private func closeLinks() {
        if let rxLink { m0110_gatt_close(rxLink) }
        if let txLink { m0110_gatt_close(txLink) }
        rxLink = nil
        txLink = nil
    }

    private func announce() {
        announced = true
        ticksSinceHello = 0
        courier.start()
        send(ClipWire.hello)
        log("clipboard: ready")
    }

    /// Tells the keyboard this helper is leaving, so the next paste does not wait for an ack.
    private func goodbye() {
        courier.stop()
        outbox.dropClip()
        clip = nil
        send(ClipWire.bye)
        announced = false
    }

    private func drop(retryIn delay: TimeInterval = 0) {
        courier.stop()
        announced = false
        open = false
        writing = false
        outbox.removeAll()
        clip = nil
        retryAfter = Date().addingTimeInterval(delay)
        queue.async { [self] in closeLinks() }
    }

    func shutdown() {
        guard open else { return }
        courier.stop()
        if announced, let rxLink = queue.sync(execute: { self.rxLink }) {
            let bye = [UInt8](ClipWire.bye)
            queue.sync { _ = m0110_gatt_write(rxLink, bye, UInt32(bye.count)) }
        }
        announced = false
        open = false
        queue.sync { closeLinks() }
    }

    // MARK: Frames

    private func received(_ frame: [UInt8]) {
        guard open else { return }
        courier.receive(frame)
    }

    private func send(_ frame: Data) {
        outbox.send(frame)
        pump()
    }

    private func sendClip(_ payload: [UInt8], flags: UInt8) {
        clip = (payload, flags)
        outbox.sendClip(ClipWire.transfer(payload, flags: flags, frameCap: Self.frameSizes[frameSize]))
        pump()
    }

    private func pump() {
        guard open, !writing, let frame = outbox.next() else { return }
        writing = true
        let bytes = [UInt8](frame)
        queue.async { [self] in
            let result = rxLink.map { m0110_gatt_write($0, bytes, UInt32(bytes.count)) } ?? Int32(-1)
            Main.async { [self] in wrote(bytes, result) }
        }
    }

    private func wrote(_ frame: [UInt8], _ result: Int32) {
        guard writing else { return } // Dropped while writing.
        writing = false
        let isClip = [ClipWire.Frame.begin, .data, .end].contains { $0.rawValue == frame.first }
        if result == 0 {
            failures = 0
            if isClip, frame.first == ClipWire.Frame.end.rawValue { clip = nil }
        } else if frame.count > Self.frameSizes.last!, frameSize + 1 < Self.frameSizes.count,
                  frame.count > Self.frameSizes[frameSize + 1] {
            // Too long for this link. Step down a size and restart the clip in frames that fit.
            frameSize += 1
            log("clipboard: writes of \(frame.count) bytes fail (\(hex(result))); "
                + "trying \(Self.frameSizes[frameSize])")
            if let clip {
                outbox.sendClip(ClipWire.transfer(clip.payload, flags: clip.flags,
                                                  frameCap: Self.frameSizes[frameSize]))
            }
        } else {
            failures += 1
            log("clipboard: a write failed (\(hex(result)))")
            if failures >= 3 {
                log("clipboard: link down")
                drop(retryIn: 5)
                return
            }
        }
        pump()
    }
}

func gattUUID(_ string: String) -> [UInt8] {
    let u = UUID(uuidString: string)!.uuid
    return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
}
