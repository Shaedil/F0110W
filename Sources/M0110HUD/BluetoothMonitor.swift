import CoreBluetooth
import Foundation

/// Tracks whether the target keyboard is connected to the system and reads its
/// battery level from the standard Battery Service.
///
/// Presence comes from polling `retrieveConnectedPeripherals`, which reports
/// peripherals connected to *the system*; the keyboard's HID link belongs to
/// macOS, not to this app. Battery comes from its own GATT link, opened
/// alongside that one.
final class BluetoothMonitor: NSObject {
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevelChar = CBUUID(string: "2A19")
    static let hidService = CBUUID(string: "1812")

    private static let savedIdentifierKey = "peripheralIdentifier"
    private let pollInterval: TimeInterval = 2
    private let reconnectDelay: TimeInterval = 3

    private var central: CBCentralManager!
    private var timer: Timer?
    private var peripheral: CBPeripheral?
    private var isPresent = false
    private var linkPending = false
    /// True until the first presence poll completes, so a keyboard that was
    /// already connected at launch can be reported as pre-existing.
    private var awaitingFirstPoll = true

    private let config: Config
    private(set) var battery: Int?
    /// The name the device actually reports, which is what macOS shows in
    /// Bluetooth settings. Falls back to the configured match string.
    private(set) var displayName: String

    /// Fires when the keyboard appears, with the device's name and whatever
    /// battery level we last knew. The flag is true when it was already
    /// connected at launch rather than having just connected.
    var onConnect: ((String, Int?, Bool) -> Void)?
    var onDisconnect: ((String) -> Void)?
    /// Fires on every fresh battery reading.
    var onBattery: ((String, Int) -> Void)?

    init(config: Config) {
        self.config = config
        self.displayName = config.deviceName
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func log(_ msg: String) {
        guard config.verbose else { return }
        print("[\(Self.timestamp())] \(msg)")
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    // MARK: - Presence polling

    private func startPolling() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    private func matches(_ p: CBPeripheral) -> Bool {
        if let name = p.name, name == config.deviceName { return true }
        // Name can come back nil; fall back to the identifier we matched before.
        if let saved = UserDefaults.standard.string(forKey: Self.savedIdentifierKey) {
            return p.identifier.uuidString == saved
        }
        return false
    }

    private func poll() {
        guard central.state == .poweredOn else { return }
        let connected = central.retrieveConnectedPeripherals(
            withServices: [Self.batteryService, Self.hidService])
        let match = connected.first(where: matches)
        let isInitial = awaitingFirstPoll
        awaitingFirstPoll = false

        switch (isPresent, match) {
        case (false, .some(let p)):
            isPresent = true
            peripheral = p
            p.delegate = self
            UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedIdentifierKey)
            if let reported = p.name, !reported.isEmpty { displayName = reported }
            log("connected: \(p.name ?? config.deviceName) [\(p.identifier)]"
                + (isInitial ? " (already connected at launch)" : ""))
            onConnect?(displayName, battery, isInitial)
            openLink()

        case (true, .none):
            isPresent = false
            log("disconnected")
            if let p = peripheral, p.state == .connected || p.state == .connecting {
                central.cancelPeripheralConnection(p)
            }
            peripheral = nil
            linkPending = false
            battery = nil
            onDisconnect?(displayName)

        case (true, .some(let p)):
            // Still here; make sure the battery link is up.
            if peripheral == nil { peripheral = p; p.delegate = self }
            openLink()

        case (false, .none):
            break
        }
    }

    /// Open our own GATT connection so we can read and subscribe to BAS.
    private func openLink() {
        guard let p = peripheral, !linkPending else { return }
        guard p.state != .connected && p.state != .connecting else {
            if battery == nil { discoverBattery(on: p) }
            return
        }
        linkPending = true
        log("opening GATT link for battery")
        central.connect(p, options: nil)
    }

    private func discoverBattery(on p: CBPeripheral) {
        if let service = p.services?.first(where: { $0.uuid == Self.batteryService }) {
            if let ch = service.characteristics?.first(where: { $0.uuid == Self.batteryLevelChar }) {
                p.readValue(for: ch)
            } else {
                p.discoverCharacteristics([Self.batteryLevelChar], for: service)
            }
        } else {
            p.discoverServices([Self.batteryService])
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothMonitor: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("bluetooth ready; watching for \"\(config.deviceName)\"")
            startPolling()
        case .unauthorized:
            FileHandle.standardError.write(
                "Bluetooth permission denied. Grant it in System Settings > Privacy & Security > Bluetooth.\n"
                    .data(using: .utf8)!)
        case .poweredOff:
            log("bluetooth off")
        default:
            log("bluetooth state: \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        linkPending = false
        log("GATT link up")
        peripheral.discoverServices([Self.batteryService])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        linkPending = false
        log("GATT link failed: \(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        linkPending = false
        log("GATT link down: \(error?.localizedDescription ?? "clean")")
        // Our link dropping doesn't mean the keyboard left; polling decides that.
        guard isPresent else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
            guard let self, self.isPresent else { return }
            self.openLink()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothMonitor: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { return log("service discovery failed: \(error!)") }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.batteryService }) else {
            return log("no Battery Service exposed")
        }
        peripheral.discoverCharacteristics([Self.batteryLevelChar], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil else { return log("characteristic discovery failed: \(error!)") }
        guard let ch = service.characteristics?.first(where: { $0.uuid == Self.batteryLevelChar }) else {
            return log("no Battery Level characteristic")
        }
        peripheral.readValue(for: ch)
        if ch.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: ch)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil else { return log("battery read failed: \(error!)") }
        guard characteristic.uuid == Self.batteryLevelChar,
              let data = characteristic.value, let raw = data.first else { return }
        let level = Int(raw)
        guard (0...100).contains(level) else { return log("battery out of range: \(raw)") }
        battery = level
        log("battery \(level)%")
        onBattery?(displayName, level)
    }
}
