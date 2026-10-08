import CoreBluetooth
import Foundation

/// Tracks whether the target keyboard is connected to the system, reads its
/// battery level from the standard Battery Service, and follows which
/// Bluetooth profile it types to.
///
/// Presence comes from polling `retrieveConnectedPeripherals`, which reports
/// peripherals connected to *the system*; the keyboard's HID link belongs to
/// macOS, not to this app. Battery and profile come from its own GATT link,
/// opened alongside that one. That link dropping is also the first sign the
/// keyboard has gone; `Presence` decides whether it really has.
final class BluetoothMonitor: NSObject {
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevelChar = CBUUID(string: "2A19")
    static let hidService = CBUUID(string: "1812")
    /// The firmware's profile report; see `config/src/profile_report.c` on the
    /// firmware branch. Firmware without it simply never reports a profile.
    static let profileService = CBUUID(string: "05B3A8EB-1160-4B0F-B56D-700006AAEFEB")
    static let profileStateChar = CBUUID(string: "05B3A8EC-1160-4B0F-B56D-700006AAEFEB")

    private static let savedIdentifierKey = "peripheralIdentifier"
    private let pollInterval: TimeInterval = 2
    private let reconnectDelay: TimeInterval = 3
    /// How long a connect waits for its battery reading before it is announced
    /// without one. The read normally lands within 200 ms of the keyboard
    /// being seen.
    private let batteryWait: TimeInterval = 1.5

    private var central: CBCentralManager!
    private var timer: Timer?
    private var peripheral: CBPeripheral?
    private var presence: Presence
    private var linkPending = false
    /// True until the first presence poll completes, so a keyboard that was
    /// already connected at launch can be reported as pre-existing.
    private var awaitingFirstPoll = true
    /// A connect seen but not yet announced, waiting on the battery read. Holds
    /// the at-launch flag `onConnect` will carry.
    private var pendingConnect: Bool?
    private var batteryTimeout: DispatchWorkItem?

    private let config: Config
    private(set) var battery: Int?
    /// The name the device actually reports, which is what macOS shows in
    /// Bluetooth settings. Falls back to the configured match string.
    private(set) var displayName: String

    /// Fires when the keyboard appears, with the device's name and the battery
    /// level read on this connect. It waits for that read, up to `batteryWait`,
    /// and passes nil if the read has not landed by then; it never passes a
    /// level from an earlier connect. The flag is true when the keyboard was
    /// already connected at launch rather than having just connected.
    var onConnect: ((String, Int?, Bool) -> Void)?
    var onDisconnect: ((String) -> Void)?
    /// Fires on every fresh battery reading.
    var onBattery: ((String, Int) -> Void)?
    /// Fires on every profile report: the profile the keyboard types to, and
    /// the one that is this computer (nil if it is not bonded to one), both
    /// 0-based. Sent on every switch and sometimes when nothing moved, so the
    /// receiver compares with what it last heard.
    var onProfile: ((String, Int, Int?) -> Void)?

    init(config: Config) {
        self.config = config
        self.displayName = config.deviceName
        self.presence = Presence(grace: config.disconnectGrace)
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

        switch presence.observe(present: match != nil, at: Date()) {
        case .arrived:
            guard let p = match else { break }
            peripheral = p
            p.delegate = self
            UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedIdentifierKey)
            if let reported = p.name, !reported.isEmpty { displayName = reported }
            log("connected: \(p.name ?? config.deviceName) [\(p.identifier)]"
                + (isInitial ? " (already connected at launch)" : ""))
            awaitBattery(isInitial: isInitial)

        case .left:
            log("disconnected")
            if let p = peripheral, p.state == .connected || p.state == .connecting {
                central.cancelPeripheralConnection(p)
            }
            peripheral = nil
            linkPending = false
            battery = nil
            if pendingConnect != nil {
                // Gone before the connect was announced: there is nothing to
                // take back, so say nothing either way.
                cancelPendingConnect()
                return
            }
            onDisconnect?(displayName)

        case .leaving(let until):
            log("keyboard missing; announcing it gone if still missing in \(presence.grace)s")
            checkPresence(at: until)

        case .stayed(let missingFor):
            log(String(format: "keyboard back within %.1fs; not announced", missingFor))

        case nil:
            break
        }

        // Still here, or back: make sure our own link is up.
        if presence.isPresent, let p = match {
            if peripheral == nil { peripheral = p; p.delegate = self }
            openLink()
        }
    }

    /// Poll once more as a grace period ends, rather than up to a poll
    /// interval after it.
    private func checkPresence(at time: Date) {
        let delay = max(0, time.timeIntervalSinceNow) + 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.poll() }
    }

    /// Hold the connect until this connect's battery read lands. Announcing at
    /// once meant announcing with the level from the last time the keyboard
    /// was here, which can be days old, and correcting it a moment later.
    private func awaitBattery(isInitial: Bool) {
        pendingConnect = isInitial
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.log("no battery reading after \(self.batteryWait)s; announcing without one")
            self.announceConnect(battery: nil)
        }
        batteryTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + batteryWait, execute: work)
    }

    /// Fire the held connect, if there is one.
    private func announceConnect(battery: Int?) {
        guard let isInitial = pendingConnect else { return }
        cancelPendingConnect()
        onConnect?(displayName, battery, isInitial)
    }

    private func cancelPendingConnect() {
        pendingConnect = nil
        batteryTimeout?.cancel()
        batteryTimeout = nil
    }

    /// Open our own GATT connection so we can read and subscribe to BAS and
    /// the profile report.
    private func openLink() {
        guard let p = peripheral, !linkPending else { return }
        guard p.state != .connected && p.state != .connecting else {
            if battery == nil { discoverBattery(on: p) }
            return
        }
        linkPending = true
        log("opening GATT link for battery and profile")
        central.connect(p, options: nil)
    }

    private static let services = [batteryService, profileService]

    /// The one characteristic wanted from each service.
    private static func characteristic(for service: CBUUID) -> CBUUID? {
        switch service {
        case batteryService: return batteryLevelChar
        case profileService: return profileStateChar
        default: return nil
        }
    }

    private func discoverBattery(on p: CBPeripheral) {
        if let service = p.services?.first(where: { $0.uuid == Self.batteryService }) {
            if let ch = service.characteristics?.first(where: { $0.uuid == Self.batteryLevelChar }) {
                p.readValue(for: ch)
            } else {
                p.discoverCharacteristics([Self.batteryLevelChar], for: service)
            }
        } else {
            p.discoverServices(Self.services)
        }
    }

    /// Both 0-based; `own` is nil when this computer is not bonded to any
    /// profile. Later firmware may append fields, which are ignored.
    static func parseProfileState(_ data: Data) -> (active: Int, own: Int?)? {
        guard data.count >= 2 else { return nil }
        let bytes = [UInt8](data.prefix(2))
        return (Int(bytes[0]), bytes[1] == 0xFF ? nil : Int(bytes[1]))
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
        peripheral.discoverServices(Self.services)
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
        guard presence.isPresent else { return }
        // Usually the keyboard going, but our link can also drop on its own,
        // so this only starts the clock and polling decides.
        if case .leaving(let until)? = presence.linkDropped(at: Date()) {
            log("keyboard may have gone; checking again in \(presence.grace)s")
            checkPresence(at: until)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
            guard let self, self.presence.isPresent else { return }
            self.openLink()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothMonitor: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { return log("service discovery failed: \(error!)") }
        let services = peripheral.services ?? []
        if !services.contains(where: { $0.uuid == Self.batteryService }) {
            log("no Battery Service exposed")
        }
        if !services.contains(where: { $0.uuid == Self.profileService }) {
            log("no profile report exposed; the firmware predates it")
        }
        for service in services {
            guard let ch = Self.characteristic(for: service.uuid) else { continue }
            peripheral.discoverCharacteristics([ch], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil else { return log("characteristic discovery failed: \(error!)") }
        guard let wanted = Self.characteristic(for: service.uuid),
              let ch = service.characteristics?.first(where: { $0.uuid == wanted }) else {
            return log("no characteristic found in \(service.uuid)")
        }
        peripheral.readValue(for: ch)
        if ch.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: ch)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil else { return log("read of \(characteristic.uuid) failed: \(error!)") }
        if characteristic.uuid == Self.profileStateChar {
            guard let data = characteristic.value, let report = Self.parseProfileState(data) else {
                return log("profile report malformed")
            }
            log("profile \(report.active) active; this computer is "
                + (report.own.map { "profile \($0)" } ?? "not bonded to one"))
            onProfile?(displayName, report.active, report.own)
            return
        }
        guard characteristic.uuid == Self.batteryLevelChar,
              let data = characteristic.value, let raw = data.first else { return }
        let level = Int(raw)
        guard (0...100).contains(level) else { return log("battery out of range: \(raw)") }
        battery = level
        log("battery \(level)%")
        // The first reading on a connect is what the connect was waiting for.
        announceConnect(battery: level)
        onBattery?(displayName, level)
    }
}
