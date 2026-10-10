import CoreBluetooth
import Foundation

/// Blocking Studio transport over the firmware's GATT RPC characteristic, with
/// the same framing and protobuf messages as serial
/// (`zmk/app/src/studio/gatt_rpc_transport.c`). The firmware only serves RPC on
/// the current output endpoint (`refresh_selected_transport` in `rpc.c`), so
/// this fails while output is USB, the default when plugged in. The Fn layer's
/// `&out OUT_BLE` switches it. `StudioClient` blocks on its own queue while
/// CoreBluetooth calls back on another, so waiting on the shared `NSCondition`
/// cannot block the callback that would end the wait.
final class BLETransport: NSObject, StudioTransport {
    /// `ZMK_BT_STUDIO_UUID` from `zmk/app/src/studio/uuid.h`.
    static let serviceUUID = CBUUID(string: "00000000-0196-6107-C967-C5CFB1C2482A")
    static let rpcCharacteristicUUID = CBUUID(string: "00000001-0196-6107-C967-C5CFB1C2482A")
    /// Fallback route to the peripheral. See `findPeripheral`.
    private static let hidServiceUUID = CBUUID(string: "1812")

    /// Time `open` gets to connect and subscribe.
    private static let setupTimeout: TimeInterval = 8
    private static let writeTimeout: TimeInterval = 3

    let label = "Bluetooth"

    /// Silence allowed before the link counts as dead. The firmware sends 27 bytes
    /// per indication and waits for each confirm, so a big reply (layouts, keymap)
    /// can outlast any fixed total.
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

    /// Records the first fatal error and wakes any waiter. Call on `queue`.
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

        // The firmware reassembles from a ring buffer, so a frame can be split
        // across writes, but each write must fit the negotiated ATT payload.
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

    /// The timeout counts silence, so it restarts whenever data arrives.
    func receiveFrame(timeout: TimeInterval) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        lastActivity = Date()
        while frames.isEmpty, failure == nil {
            let deadline = lastActivity.addingTimeInterval(timeout)
            if Date() >= deadline {
                // The byte count shows whether the firmware stalled mid-message or never answered.
                log("studio/ble: gave up after \(bytesSeen) bytes with no complete frame")
                throw StudioError.timeout("a response frame over Bluetooth")
            }
            // Re-reading `lastActivity` each loop lets new data push the deadline out.
            _ = lock.wait(until: deadline)
        }
        if let failure { throw failure }
        return frames.removeFirst()
    }

    func receiveFrameIfAvailable() throws -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        return frames.isEmpty ? nil : frames.removeFirst()
    }

    // MARK: - Finding the keyboard

    /// The keyboard is already connected to macOS for HID, so it is retrieved
    /// instead of scanned for (ZMK does not advertise the Studio service).
    /// macOS may not have cached the Studio service yet, so the HID service,
    /// narrowed by name, is the fallback.
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
        // Replies come as indications, so the link is not ready until this succeeds.
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            // The characteristic needs an encrypted link, so an unpaired keyboard fails here.
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
        // The firmware caps indications at 27 bytes, so the decoder rebuilds each reply.
        lock.lock()
        lastActivity = Date()
        bytesSeen += data.count
        for byte in data {
            if let frame = decoder.feed(byte) { frames.append(frame) }
        }
        // Wake waiters even without a full frame so they see the new activity.
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
