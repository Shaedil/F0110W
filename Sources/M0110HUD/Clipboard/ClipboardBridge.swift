import AppKit
import CoreBluetooth
import IOKit

/// Carries this Mac's clipboard to the keyboard, and takes delivery of clips
/// the keyboard is carrying from another computer.
///
/// A keyboard cannot read a clipboard, so the copy side needs someone to hand
/// the text over: this. Each time the pasteboard changes, the new text is
/// written to the firmware's clipboard service. The keyboard holds it, and
/// after a switch to another computer either gives it to the bridge running
/// there, which puts it on that pasteboard, or types it out if nothing is
/// running there.
///
/// This class is the Bluetooth link: finding the keyboard, and getting frames
/// to and from it. What goes in them, including how an image gets across, is
/// `ClipCourier`'s business.
///
/// ## Threading
///
/// Everything runs on the main queue: CoreBluetooth is given it, the timers
/// are scheduled on it, and `NSPasteboard` wants it.
final class ClipboardBridge: NSObject {
    /// Must match `CLIP_UUID` in the firmware's `config/clipboard/clipboard.c`.
    static let serviceUUID = CBUUID(string: "B02961DE-EEC8-443B-9EDE-2919A6354188")
    static let rxUUID = CBUUID(string: "B02961DF-EEC8-443B-9EDE-2919A6354188")
    static let txUUID = CBUUID(string: "B02961E0-EEC8-443B-9EDE-2919A6354188")
    private static let batteryServiceUUID = CBUUID(string: "180F")

    /// `UserDefaults` key for the on/off switch. Read live, so the Settings
    /// pane takes effect without a relaunch.
    static let enabledKey = "clipboardSync"

    /// ZMK's default USB IDs, which this firmware keeps.
    private static let usbVendorID = 0x1D50
    private static let usbProductID = 0x615E

    private static let tickInterval: TimeInterval = 2
    private static let pasteboardInterval: TimeInterval = 0.3
    /// Ticks between HELLOs. The firmware stops waiting on a helper that
    /// misses an acknowledgement; this is what gets it trusted again.
    private static let helloEveryTicks = 15

    private let deviceName: String
    private let log: (String) -> Void

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    /// Notifications are on, so the keyboard's replies and deliveries arrive.
    private var subscribed = false
    /// HELLO has been sent: the keyboard counts this Mac as having a helper.
    private var announced = false
    private var retryAfter = Date.distantPast
    /// The keyboard has no usable clipboard service, which is what older
    /// firmware looks like. It is left completely alone until it reconnects,
    /// which a reflash forces: probing it again on a timer opens a second GATT
    /// connection to the keyboard every time, and the HUD has no business
    /// doing that to firmware that cannot answer.
    private var unsupported = false
    private var ticksSinceHello = 0
    private var lastLogged = ""

    private var tickTimer: Timer?
    private var pasteboardTimer: Timer?

    private let courier: ClipCourier

    private var outbox = ClipOutbox()

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    init(deviceName: String, log: @escaping (String) -> Void = { _ in }) {
        self.deviceName = deviceName
        self.log = log
        courier = ClipCourier(channel: ClipChannel(log: log), log: log)
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)

        courier.send = { [weak self] frame in self?.send(frame) }
        courier.sendClip = { [weak self] payload, flags in self?.sendClip(payload, flags: flags) }
        courier.dropQueuedClip = { [weak self] in self?.outbox.dropClip() }
        courier.frameCap = { [weak self] in
            self?.peripheral?.maximumWriteValueLength(for: .withoutResponse) ?? 20
        }
        courier.keyboardIsOnUSB = { [weak self] in self?.keyboardIsOnUSB() ?? false }

        let tick = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(tick, forMode: .common)
        tickTimer = tick

        let watch = Timer(timeInterval: Self.pasteboardInterval, repeats: true) { [weak self] _ in
            self?.courier.checkPasteboard()
        }
        RunLoop.main.add(watch, forMode: .common)
        pasteboardTimer = watch
    }

    /// Tell the keyboard this helper is going, so the next paste on this Mac
    /// does not wait on an acknowledgement that will never come.
    func shutdown() {
        tickTimer?.invalidate()
        pasteboardTimer?.invalidate()
        courier.stop()
        guard announced else { return }
        // Nothing may be left behind the goodbye either: the app is about to
        // exit, and half a clip would sit in the keyboard until it expired.
        outbox.dropClip()
        send(ClipWire.bye)
        announced = false
    }

    // MARK: - Link

    /// Logs a line unless it repeats the last one, so a condition that holds
    /// across many ticks is reported when it starts rather than every time.
    private func logOnce(_ message: String) {
        guard message != lastLogged else { return }
        lastLogged = message
        log(message)
    }

    private func tick() {
        ticksSinceHello += 1

        guard central.state == .poweredOn else {
            logOnce("clipboard: Bluetooth is not ready (state \(central.state.rawValue))")
            return
        }
        guard let peripheral else {
            search()
            return
        }
        guard subscribed, peripheral.state == .connected else { return }

        // CoreBluetooth signals when it can take more writes, but a signal
        // missed here would strand the queue for good.
        pump()

        if enabled, !announced {
            announce()
        } else if !enabled, announced {
            log("clipboard: switched off")
            shutdownLink()
        } else if announced, ticksSinceHello >= Self.helloEveryTicks, !courier.busy {
            ticksSinceHello = 0
            send(ClipWire.hello)
        }
    }

    /// The keyboard is already connected to macOS for HID, so it is retrieved
    /// rather than scanned for.
    ///
    /// The lookup returns peripherals known to have any of the services
    /// named. The clipboard service is not known until it has been discovered
    /// once, and macOS keeps the HID service to itself, so on a freshly
    /// flashed keyboard it is the battery service that finds it.
    private func search() {
        guard enabled, !unsupported, Date() >= retryAfter else { return }

        let connected = central.retrieveConnectedPeripherals(
            withServices: [Self.serviceUUID, Self.batteryServiceUUID])
        let saved = UserDefaults.standard.string(forKey: "peripheralIdentifier")
        guard let found = connected.first(where: {
            $0.name == deviceName || $0.identifier.uuidString == saved
        }) else {
            let names = connected.map { $0.name ?? $0.identifier.uuidString }
            logOnce("clipboard: no connected keyboard named \(deviceName) (connected: \(names))")
            return
        }

        log("clipboard: connecting to \(found.name ?? found.identifier.uuidString)")
        peripheral = found
        found.delegate = self
        central.connect(found, options: nil)
    }

    private func announce() {
        announced = true
        ticksSinceHello = 0
        courier.start()
        send(ClipWire.hello)
        log("clipboard: ready")
    }

    private func shutdownLink() {
        courier.stop()
        send(ClipWire.bye)
        announced = false
        outbox.dropClip()
    }

    /// Gives up on this keyboard until `keyboardReconnected()`.
    private func markUnsupported() {
        unsupported = true
        drop()
    }

    /// The keyboard went away and came back, so it may be running new
    /// firmware. Whatever was concluded about its services no longer holds.
    func keyboardReconnected() {
        unsupported = false
        retryAfter = .distantPast
    }

    private func drop(retryIn delay: TimeInterval = 0) {
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        rx = nil
        subscribed = false
        announced = false
        outbox.removeAll()
        courier.stop()
        retryAfter = Date().addingTimeInterval(delay)
    }

    // MARK: - Sending

    private func send(_ frame: Data) {
        outbox.send(frame)
        pump()
    }

    /// Writes are without response, so a clip crosses in a handful of
    /// connection events instead of one round trip per frame. CoreBluetooth
    /// says when it can take more.
    private func pump() {
        guard let peripheral, let rx, peripheral.state == .connected else { return }
        while peripheral.canSendWriteWithoutResponse, let frame = outbox.next() {
            peripheral.writeValue(frame, for: rx, type: .withoutResponse)
        }
    }

    /// Queues a clip. A newer clip replaces whatever of the last one is still
    /// queued.
    private func sendClip(_ payload: [UInt8], flags: UInt8) {
        let cap = peripheral?.maximumWriteValueLength(for: .withoutResponse) ?? 20
        outbox.sendClip(ClipWire.transfer(payload, flags: flags, frameCap: cap))
        pump()
    }

    /// Whether the keyboard is also plugged into this Mac.
    ///
    /// The firmware needs to know, because it cannot tell on its own that its
    /// USB port and one of its Bluetooth profiles are the same computer. If it
    /// guessed wrong it would type this Mac's own clipboard back at it.
    private func keyboardIsOnUSB() -> Bool {
        guard let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else {
            return false
        }
        matching["idVendor"] = Self.usbVendorID
        matching["idProduct"] = Self.usbProductID

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return false }
        defer { IOObjectRelease(iterator) }

        // The IDs are ZMK's defaults and shared by every ZMK keyboard, so the
        // product name is what says this one is ours.
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let name = IORegistryEntryCreateCFProperty(
                service, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if let name, name.localizedCaseInsensitiveContains(deviceName) { return true }
        }
        return false
    }
}

// MARK: - CBCentralManagerDelegate

extension ClipboardBridge: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            // The peripheral object does not survive a power cycle or a reset.
            peripheral = nil
            rx = nil
            subscribed = false
            announced = false
            outbox.removeAll()
            courier.stop()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        log("clipboard: could not connect (\(error?.localizedDescription ?? "unknown"))")
        drop()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // `drop` cancels the connection itself and has already let go of the
        // peripheral by the time that lands here; only an unexpected loss
        // should reset the retry clock.
        guard peripheral === self.peripheral else { return }
        log("clipboard: link down")
        drop()
    }
}

// MARK: - CBPeripheralDelegate

extension ClipboardBridge: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID })
        else {
            log("clipboard: the keyboard's firmware has no clipboard service")
            markUnsupported()
            return
        }
        peripheral.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let characteristics = service.characteristics ?? []
        guard error == nil,
              let rx = characteristics.first(where: { $0.uuid == Self.rxUUID }),
              let tx = characteristics.first(where: { $0.uuid == Self.txUUID })
        else {
            log("clipboard: the clipboard service is missing a characteristic")
            markUnsupported()
            return
        }
        self.rx = rx
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            // The service needs an encrypted link, so this is where a keyboard
            // that is connected but not paired shows up.
            log("clipboard: could not subscribe (\(error.localizedDescription))")
            markUnsupported()
            return
        }
        subscribed = characteristic.isNotifying
        guard subscribed, enabled else { return }
        announce()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == Self.txUUID,
              let data = characteristic.value else { return }
        courier.receive([UInt8](data))
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pump()
    }

    /// The firmware was reflashed with a different set of services.
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard invalidatedServices.contains(where: { $0.uuid == Self.serviceUUID }) else { return }
        log("clipboard: services changed; reconnecting")
        drop()
    }
}
