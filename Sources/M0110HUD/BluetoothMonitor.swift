import CoreBluetooth
import Foundation

/// Tracks the keyboard's connection, battery level and active Bluetooth profile. Presence
/// comes from polling `retrieveConnectedPeripherals`, since macOS owns the HID link. Battery
/// and profile come from a second GATT link opened by this app. When that link drops,
/// `Presence` decides whether the keyboard really left.
final class BluetoothMonitor: NSObject {
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevelChar = CBUUID(string: "2A19")
    static let hidService = CBUUID(string: "1812")
    /// The firmware's profile report (`config/src/profile_report.c`). Older firmware never sends it.
    static let profileService = CBUUID(string: "05B3A8EB-1160-4B0F-B56D-700006AAEFEB")
    static let profileStateChar = CBUUID(string: "05B3A8EC-1160-4B0F-B56D-700006AAEFEB")
    /// Profile names stored on the keyboard; see `ProfileNamesWire`.
    static let profileNamesChar = CBUUID(string: "05B3A8ED-1160-4B0F-B56D-700006AAEFEB")

    private static let savedIdentifierKey = "peripheralIdentifier"
    private let pollInterval: TimeInterval = 2
    private let reconnectDelay: TimeInterval = 3
    /// How long a connect waits for its battery reading. The read usually arrives within 200 ms.
    private let batteryWait: TimeInterval = 1.5

    private var central: CBCentralManager!
    private var timer: Timer?
    private var peripheral: CBPeripheral?
    private var presence: Presence
    private var linkPending = false
    /// True until the first poll, so a keyboard already connected at launch is reported as such.
    private var awaitingFirstPoll = true
    /// A connect waiting on its battery read. Holds the at-launch flag for `onConnect`.
    private var pendingConnect: Bool?
    private var batteryTimeout: DispatchWorkItem?
    /// Nil on firmware that does not store names.
    private var namesChar: CBCharacteristic?
    /// Names counter from the profile report. A change means the names must be read again.
    private var namesGeneration: UInt8?
    /// Writes not yet answered, oldest first. CoreBluetooth answers writes to one
    /// characteristic in order.
    private var namesInFlight: [ProfileNameSync.Write] = []
    /// This computer's profile, as reported over the current link. Not carried over between
    /// links, since the computer may have been paired to another profile in between.
    private(set) var reportedOwn: Int?

    private let config: Config
    private(set) var battery: Int?
    /// The name the device reports (what macOS shows in Bluetooth settings), or the configured name.
    private(set) var displayName: String

    /// Name, this connect's battery level (nil if not read within `batteryWait`, never an
    /// old level), and whether the keyboard was already connected at launch.
    var onConnect: ((String, Int?, Bool) -> Void)?
    var onDisconnect: ((String) -> Void)?
    var onBattery: ((String, Int) -> Void)?
    /// Active profile and this computer's (nil if not bonded), 0-based. May repeat unchanged.
    var onProfile: ((String, Int, Int?) -> Void)?
    /// One name per profile ("" if unset), plus which names the keyboard read from the device.
    var onNames: (([String], Set<Int>) -> Void)?
    /// The Bool is whether the keyboard accepted the write.
    var onNameWritten: ((ProfileNameSync.Write, Bool) -> Void)?

    var canWriteNames: Bool { namesChar != nil && peripheral?.state == .connected }
    var isWritingNames: Bool { !namesInFlight.isEmpty }

    func write(_ name: ProfileNameSync.Write) {
        guard let p = peripheral, let ch = namesChar, p.state == .connected else { return }
        log("naming Profile \(name.index + 1) \"\(name.name)\" (\(name.op == .auto ? "if unnamed" : "set"))")
        namesInFlight.append(name)
        p.writeValue(ProfileNamesWire.write(name.op, index: name.index, name: name.name),
                     for: ch, type: .withResponse)
    }

    private func readNames() {
        guard let p = peripheral, let ch = namesChar, p.state == .connected else { return }
        p.readValue(for: ch)
    }

    private func forgetLink() {
        namesChar = nil
        namesGeneration = nil
        namesInFlight.removeAll()
        reportedOwn = nil
    }

    init(config: Config) {
        self.config = config
        self.displayName = config.deviceName
        self.presence = Presence(grace: config.disconnectGrace)
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func log(_ msg: String) {
        DebugLog.shared.add(.bluetooth, msg)
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
        // The name can be nil, so fall back to the saved identifier.
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
            forgetLink()
            if pendingConnect != nil {
                // Left before the connect was announced, so say nothing.
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

        if presence.isPresent, let p = match {
            if peripheral == nil { peripheral = p; p.delegate = self }
            openLink()
        }
    }

    /// Polls right when the grace period ends instead of up to one poll interval later.
    private func checkPresence(at time: Date) {
        let delay = max(0, time.timeIntervalSinceNow) + 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.poll() }
    }

    /// Holds the connect until its battery read arrives, so the HUD never shows a stale level.
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

    private static func characteristics(for service: CBUUID) -> [CBUUID] {
        switch service {
        case batteryService: return [batteryLevelChar]
        case profileService: return [profileStateChar, profileNamesChar]
        default: return []
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

    /// Byte 0 is the active profile, byte 1 this computer's (0xFF if not bonded), both 0-based.
    /// Extra bytes from newer firmware are ignored.
    static func parseProfileState(_ data: Data) -> (active: Int, own: Int?)? {
        guard data.count >= 2 else { return nil }
        let bytes = [UInt8](data.prefix(2))
        return (Int(bytes[0]), bytes[1] == 0xFF ? nil : Int(bytes[1]))
    }

    /// Byte 2 goes up whenever a name changes. Nil on firmware that does not store names.
    static func parseNamesGeneration(_ data: Data) -> UInt8? {
        data.count >= 3 ? data[data.startIndex + 2] : nil
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
        forgetLink()
        log("GATT link down: \(error?.localizedDescription ?? "clean")")
        guard presence.isPresent else { return }
        // Usually the keyboard leaving, but the link can also drop by itself, so this only
        // starts the grace timer and polling decides.
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
            let wanted = Self.characteristics(for: service.uuid)
            guard !wanted.isEmpty else { continue }
            peripheral.discoverCharacteristics(wanted, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil else { return log("characteristic discovery failed: \(error!)") }
        let found = (service.characteristics ?? []).filter {
            Self.characteristics(for: service.uuid).contains($0.uuid)
        }
        if found.isEmpty {
            return log("no characteristic found in \(service.uuid)")
        }
        if service.uuid == Self.profileService,
           !found.contains(where: { $0.uuid == Self.profileNamesChar }) {
            log("no profile names exposed; the firmware predates them")
        }
        for ch in found {
            if ch.uuid == Self.profileNamesChar { namesChar = ch }
            peripheral.readValue(for: ch)
            if ch.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: ch)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == Self.profileNamesChar else { return }
        guard !namesInFlight.isEmpty else { return }
        let name = namesInFlight.removeFirst()
        if let error {
            log("keyboard refused the name for Profile \(name.index + 1): \(error.localizedDescription)")
        }
        onNameWritten?(name, error == nil)
        // The keyboard may change a name (for example by numbering it), so read them back.
        if namesInFlight.isEmpty { readNames() }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil else { return log("read of \(characteristic.uuid) failed: \(error!)") }
        if characteristic.uuid == Self.profileNamesChar {
            guard let data = characteristic.value, let names = ProfileNamesWire.parse(data) else {
                return log("profile names malformed")
            }
            let fromDevice = ProfileNamesWire.fromDevice(data)
            log("profile names: " + names.enumerated()
                .map { "\($0.offset + 1)=\"\($0.element)\"" + (fromDevice.contains($0.offset) ? "*" : "") }
                .joined(separator: " ") + (fromDevice.isEmpty ? "" : " (* read from the device)"))
            onNames?(names, fromDevice)
            return
        }
        if characteristic.uuid == Self.profileStateChar {
            guard let data = characteristic.value, let report = Self.parseProfileState(data) else {
                return log("profile report malformed")
            }
            // Logged 1-based to match Settings. The raw bytes are 0-based.
            log("profile report: Profile \(report.active + 1) active; this computer is "
                + (report.own.map { "Profile \($0 + 1)" } ?? "not bonded to one")
                + " (raw \(data.prefix(2).map { String(format: "%02x", $0) }.joined(separator: " ")))")
            reportedOwn = report.own
            onProfile?(displayName, report.active, report.own)
            if let generation = Self.parseNamesGeneration(data), generation != namesGeneration {
                // The first report only sets the counter, since discovery reads the names itself.
                if namesGeneration != nil { readNames() }
                namesGeneration = generation
            }
            return
        }
        guard characteristic.uuid == Self.batteryLevelChar,
              let data = characteristic.value, let raw = data.first else { return }
        let level = Int(raw)
        guard (0...100).contains(level) else { return log("battery out of range: \(raw)") }
        battery = level
        log("battery \(level)%")
        // The held connect was waiting for this reading.
        announceConnect(battery: level)
        onBattery?(displayName, level)
    }
}
