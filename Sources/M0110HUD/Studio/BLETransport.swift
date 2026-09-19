import CoreBluetooth
import Foundation

/// Blocking Studio transport over the firmware's GATT RPC service.
///
/// ZMK exposes the same RPC protocol on Bluetooth that it does on the serial
/// port, with the same framing and the same protobuf envelopes, through one
/// characteristic that is written to and indicates back
/// (`zmk/app/src/studio/gatt_rpc_transport.c`). So only the byte channel is new
/// here; everything above `StudioTransport` is shared with the serial path.
///
/// ## Only one transport is live at a time
///
/// The firmware selects its RPC transport from the endpoint the keyboard is
/// currently *outputting* to (`refresh_selected_transport` in `rpc.c`), and the
/// GATT transport drops every write while it is not the selected one. So this
/// works when the keyboard's output endpoint is Bluetooth, and is deaf when the
/// endpoint is USB, which is what a plugged-in board defaults to. The keymap's
/// Fn layer has `&out OUT_BLE` for switching.
///
/// ## Bridging callbacks to a blocking call
///
/// `StudioClient` is synchronous on its own serial queue. CoreBluetooth is
/// callbacks on another. Everything shared sits behind one `NSCondition`: the
/// delegate signals, the caller waits with a deadline. The two queues are
/// always different, so the wait cannot block the callbacks that would end it.
final class BLETransport: NSObject, StudioTransport {
    /// `ZMK_BT_STUDIO_UUID` from `zmk/app/src/studio/uuid.h`.
    static let serviceUUID = CBUUID(string: "00000000-0196-6107-C967-C5CFB1C2482A")
    static let rpcCharacteristicUUID = CBUUID(string: "00000001-0196-6107-C967-C5CFB1C2482A")
    /// Used only as a fallback route to the peripheral; see `findPeripheral`.
    private static let hidServiceUUID = CBUUID(string: "1812")

    /// How long `open` waits for the whole connect-and-subscribe sequence.
    private static let setupTimeout: TimeInterval = 8
    /// How long a single chunk write waits for its acknowledgement.
    private static let writeTimeout: TimeInterval = 3

    let label = "Bluetooth"

    /// Time without *any* incoming data before the link is called dead.
    ///
    /// Not a budget for the whole reply. The firmware indicates back 27 bytes
    /// at a time and waits for each to be confirmed, so a kilobyte-scale
    /// answer (the physical layouts, the keymap) is dozens of round trips,
    /// and with the connection latency ZMK requests those can add up past any
    /// fixed figure. Budgeting the whole response meant a transfer that was
    /// progressing perfectly well got abandoned partway; measuring silence
    /// instead lets a slow reply finish while a genuinely dead link still
    /// fails quickly.
    let responseTimeout: TimeInterval = 6

    private let deviceName: String
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "m0110hud.studio.ble")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rpc: CBCharacteristic?

    /// Everything below is guarded by `lock`.
    private let lock = NSCondition()
    private var ready = false
    private var failure: StudioError?
    private var frames: [[UInt8]] = []
    private var decoder = StudioFraming.Decoder()
    private var pendingWriteAcks = 0
    /// When bytes last arrived, so waiting can be measured against silence
    /// rather than against the clock.
    private var lastActivity = Date()
    private var bytesSeen = 0

    init(deviceName: String, log: @escaping (String) -> Void = { _ in }) {
        self.deviceName = deviceName
        self.log = log
        super.init()
    }

    deinit { close() }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    // MARK: - Lifecycle

    func open() throws {
        lock.lock()
        ready = false
        failure = nil
        frames.removeAll()
        decoder = StudioFraming.Decoder()
        lock.unlock()

        central = CBCentralManager(delegate: self, queue: queue)

        // `centralManagerDidUpdateState` drives the rest of the sequence.
        try waitUntilReady()
    }

    func close() {
        if let central, let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        rpc = nil
        central = nil
        lock.lock()
        ready = false
        lock.unlock()
    }

    private func waitUntilReady() throws {
        let deadline = Date().addingTimeInterval(Self.setupTimeout)
        lock.lock()
        defer { lock.unlock() }
        while !ready, failure == nil {
            guard lock.wait(until: deadline) else {
                throw StudioError.timeout("the keyboard's Studio service over Bluetooth")
            }
        }
        if let failure { throw failure }
    }

    /// Record a terminal failure and wake whoever is waiting. On `queue`.
    private func fail(_ error: StudioError) {
        log("studio/ble: \(error)")
        lock.lock()
        if failure == nil { failure = error }
        lock.broadcast()
        lock.unlock()
    }

    // MARK: - Transport

    func send(_ payload: [UInt8]) throws {
        guard let peripheral, let rpc else {
            throw StudioError.portUnavailable("Bluetooth: not connected")
        }
        let framed = StudioFraming.wrap(payload)

        // The firmware reassembles from a ring buffer, so a frame may be split
        // across writes, but not beyond the negotiated ATT payload.
        let chunk = max(20, peripheral.maximumWriteValueLength(for: .withResponse))
        var index = 0
        while index < framed.count {
            let end = min(index + chunk, framed.count)
            let slice = Data(framed[index..<end])

            lock.lock()
            pendingWriteAcks += 1
            lock.unlock()

            peripheral.writeValue(slice, for: rpc, type: .withResponse)
            try waitForWriteAck()
            index = end
        }
    }

    private func waitForWriteAck() throws {
        let deadline = Date().addingTimeInterval(Self.writeTimeout)
        lock.lock()
        defer { lock.unlock() }
        while pendingWriteAcks > 0, failure == nil {
            guard lock.wait(until: deadline) else {
                throw StudioError.timeout("a Bluetooth write acknowledgement")
            }
        }
        if let failure { throw failure }
    }

    /// Waits for a complete frame, giving up only after `timeout` of total
    /// silence; every indication that arrives renews the clock.
    func receiveFrame(timeout: TimeInterval) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        lastActivity = Date()
        while frames.isEmpty, failure == nil {
            let deadline = lastActivity.addingTimeInterval(timeout)
            if Date() >= deadline {
                // The byte count is the useful part: a partial count means the
                // firmware stalled mid-message rather than never answering.
                log("studio/ble: gave up after \(bytesSeen) bytes with no complete frame")
                throw StudioError.timeout("a response frame over Bluetooth")
            }
            // The wait can return early; the loop re-reads `lastActivity`, so
            // data arriving mid-wait pushes the deadline out.
            _ = lock.wait(until: deadline)
        }
        if let failure { throw failure }
        return frames.removeFirst()
    }

    // MARK: - Finding the keyboard

    /// The keyboard is already paired and connected to macOS for HID, so it is
    /// retrieved rather than scanned for: ZMK does not put the Studio service
    /// in its advertising data, and a scan would never match on it.
    ///
    /// Asking by Studio UUID only finds the peripheral once macOS has cached
    /// that service, which it has not necessarily done; the HID service is the
    /// fallback, narrowed by name.
    private func findPeripheral(_ central: CBCentralManager) -> CBPeripheral? {
        let byStudio = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID])
        if let match = byStudio.first { return match }

        let byHID = central.retrieveConnectedPeripherals(withServices: [Self.hidServiceUUID])
        return byHID.first { ($0.name ?? "").localizedCaseInsensitiveContains(deviceName) }
            ?? byHID.first
    }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            guard let found = findPeripheral(central) else {
                fail(.portUnavailable("Bluetooth: no connected keyboard exposes the Studio service"))
                return
            }
            log("studio/ble: connecting to \(found.name ?? found.identifier.uuidString)")
            peripheral = found
            found.delegate = self
            central.connect(found, options: nil)
        case .unauthorized:
            fail(.portUnavailable("Bluetooth: the app is not authorised to use Bluetooth"))
        case .poweredOff:
            fail(.portUnavailable("Bluetooth: turned off"))
        case .unsupported:
            fail(.portUnavailable("Bluetooth: unsupported on this Mac"))
        default:
            break   // .resetting / .unknown resolve into another callback
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail(.portUnavailable("Bluetooth: could not connect (\(error?.localizedDescription ?? "unknown"))"))
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        fail(.portUnavailable("Bluetooth: the link dropped"))
    }
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            fail(.portUnavailable("Bluetooth: service discovery failed (\(error.localizedDescription))"))
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            fail(.portUnavailable("Bluetooth: the keyboard is not exposing the Studio service"))
            return
        }
        peripheral.discoverCharacteristics([Self.rpcCharacteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            fail(.portUnavailable("Bluetooth: characteristic discovery failed (\(error.localizedDescription))"))
            return
        }
        guard let characteristic = service.characteristics?
            .first(where: { $0.uuid == Self.rpcCharacteristicUUID }) else {
            fail(.portUnavailable("Bluetooth: the Studio service has no RPC characteristic"))
            return
        }
        rpc = characteristic
        // Responses arrive as indications, so subscribing is what opens the
        // return path; the transport is not usable until it succeeds.
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            // The characteristic needs an encrypted link, so this is where an
            // unbonded or un-paired keyboard shows up.
            fail(.portUnavailable("Bluetooth: could not subscribe (\(error.localizedDescription))"))
            return
        }
        guard characteristic.isNotifying else { return }
        log("studio/ble: subscribed")
        lock.lock()
        ready = true
        lock.broadcast()
        lock.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            fail(.portUnavailable("Bluetooth: read failed (\(error.localizedDescription))"))
            return
        }
        guard let data = characteristic.value else { return }
        // Indications are capped at 27 bytes by the firmware, so one response
        // arrives across many of them and the decoder does the reassembly.
        lock.lock()
        lastActivity = Date()
        bytesSeen += data.count
        for byte in data {
            if let frame = decoder.feed(byte) { frames.append(frame) }
        }
        // Broadcast even without a completed frame, so a waiter wakes and sees
        // the renewed activity rather than timing out mid-transfer.
        lock.broadcast()
        lock.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            fail(.portUnavailable("Bluetooth: write failed (\(error.localizedDescription))"))
            return
        }
        lock.lock()
        pendingWriteAcks = max(0, pendingWriteAcks - 1)
        lock.broadcast()
        lock.unlock()
    }
}
