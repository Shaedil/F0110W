import CM0110Win
import Foundation

private func uuid(_ string: String) -> [UInt8] {
    let u = UUID(uuidString: string)!.uuid
    return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
}

private final class GattLink {
    private let gatt: OpaquePointer
    private let onValue: ([UInt8]) -> Void
    /// Holds this object for the C callback until closed.
    private var retained: Unmanaged<GattLink>?

    /// Nil if the service or characteristic is missing, with the HRESULT in `error`.
    init?(instance: String, service: [UInt8], characteristic: [UInt8], error: inout Int32,
          onValue: @escaping ([UInt8]) -> Void) {
        var status: Int32 = 0
        guard let gatt = m0110_gatt_open(instance.wide, service, characteristic, &status) else {
            error = status
            return nil
        }
        self.gatt = gatt
        self.onValue = onValue
    }

    func read(capacity: Int = 64) -> Result<[UInt8], GattError> {
        var buffer = [UInt8](repeating: 0, count: capacity)
        let count = m0110_gatt_read(gatt, &buffer, UInt32(buffer.count))
        guard count >= 0 else { return .failure(GattError(code: count)) }
        return .success(Array(buffer.prefix(Int(count))))
    }

    /// `onValue` runs on a system thread. Returns 0 or an HRESULT.
    func subscribe() -> Int32 {
        let me = Unmanaged.passRetained(self)
        let result = m0110_gatt_subscribe(gatt, { context, data, length in
            guard let context, let data else { return }
            let link = Unmanaged<GattLink>.fromOpaque(context).takeUnretainedValue()
            link.onValue(Array(UnsafeBufferPointer(start: data, count: Int(length))))
        }, me.toOpaque())
        if result == 0 {
            retained = me
        } else {
            me.release()
        }
        return result
    }

    func write(_ bytes: [UInt8]) -> Int32 {
        m0110_gatt_write(gatt, bytes, UInt32(bytes.count))
    }

    func close() {
        m0110_gatt_close(gatt)
        retained?.release()
        retained = nil
    }
}

struct GattError: Error, CustomStringConvertible {
    var code: Int32
    var description: String { hex(code) }
}

/// Windows version of BluetoothMonitor. Presence is polled from the device's connected
/// state, which Windows tracks no matter who holds the link. Battery and profile use GATT
/// reads plus notifications on a separate queue, because Win32 GATT calls can block for seconds.
final class WinBluetoothMonitor {
    static let batteryService = uuid("0000180F-0000-1000-8000-00805F9B34FB")
    static let batteryLevel = uuid("00002A19-0000-1000-8000-00805F9B34FB")
    static let profileService = uuid("05B3A8EB-1160-4B0F-B56D-700006AAEFEB")
    static let profileState = uuid("05B3A8EC-1160-4B0F-B56D-700006AAEFEB")
    static let profileNames = uuid("05B3A8ED-1160-4B0F-B56D-700006AAEFEB")
    /// Five names of up to 24 bytes, with their lengths and a header.
    private static let namesCapacity = 256

    /// Faster than the Mac's 2 s poll, since Windows has no link of its own that drops first.
    private let pollInterval = 1.0
    private let batteryWait = 1.5
    private let batteryReread = 60.0

    private let config: Config
    private let worker = DispatchQueue(label: "M0110HUD.bluetooth")
    private var presence: Presence
    private var awaitingFirstPoll = true
    private var pendingConnect: Bool?
    private var batteryTimeout: UInt32?
    private var rereadTimer: UInt32?
    private var polling = false
    private var stopped = false

    // Worker queue only.
    private var instance: String?
    private var lastLookup = -Double.infinity
    private var links: [GattLink] = []
    private var namesLink: GattLink?

    // App thread only.
    /// This PC's profile as reported since the links opened. Not kept across links, because
    /// the PC may have been paired to another profile in between.
    private(set) var reportedOwn: Int?
    private(set) var canWriteNames = false
    private var namesGeneration: UInt8?
    private var namesInFlight = 0
    var isWritingNames: Bool { namesInFlight > 0 }

    private(set) var battery: Int?
    var displayName: String { config.deviceName }

    var onConnect: ((String, Int?, Bool) -> Void)?
    var onDisconnect: ((String) -> Void)?
    var onBattery: ((String, Int) -> Void)?
    var onProfile: ((String, Int, Int?) -> Void)?
    /// One name per profile ("" if unset), and which ones came from the device.
    var onNames: (([String], Set<Int>) -> Void)?
    /// The Bool is whether the keyboard accepted the write.
    var onNameWritten: ((ProfileNameSync.Write, Bool) -> Void)?
    /// Device instance on connect, nil on disconnect. The clipboard opens its own GATT link with it.
    var onLink: ((String?) -> Void)?

    init(config: Config) {
        self.config = config
        presence = Presence(grace: config.disconnectGrace)
    }

    private func log(_ message: String) { M0110HUD.log(message, verbose: config.verbose) }

    func start() {
        log("watching for \"\(config.deviceName)\"")
        poll()
    }

    func stop() {
        stopped = true
        worker.async { [self] in closeLinks() }
    }

    // MARK: Presence

    private func poll() {
        guard !polling, !stopped else { return }
        polling = true
        let first = awaitingFirstPoll
        worker.async { [self] in
            let present = isConnected(firstPoll: first)
            let found = instance
            Main.async { [self] in
                polling = false
                observe(present: present, instance: found)
                if !stopped { Main.after(pollInterval) { [weak self] in self?.poll() } }
            }
        }
    }

    /// Worker only.
    private func isConnected(firstPoll: Bool) -> Bool {
        // Look it up again after unpairing, or every 30 s while not found, in case it gets paired.
        if instance == nil, Main.now - lastLookup >= 30 {
            lastLookup = Main.now
            var buffer = [UInt16](repeating: 0, count: 512)
            if m0110_ble_find(config.deviceName.wide, &buffer, UInt32(buffer.count)) != 0 {
                instance = String(wide: buffer)
                log("found \(instance!)")
            } else if firstPoll {
                log("no paired Bluetooth LE device called \"\(config.deviceName)\"; pair it in Settings")
            }
        }
        guard let instance else { return false }
        var source: Int32 = 0
        switch m0110_ble_connected(instance.wide, &source) {
        case 1: return true
        case 0: return false
        default:
            log("\(instance) is no longer paired")
            self.instance = nil
            lastLookup = -.infinity
            return false
        }
    }

    private func observe(present: Bool, instance found: String?) {
        let isInitial = awaitingFirstPoll
        awaitingFirstPoll = false

        switch presence.observe(present: present, at: Date()) {
        case .arrived:
            log("connected" + (isInitial ? " (already connected at launch)" : ""))
            awaitBattery(isInitial: isInitial)
            openLinks()
            onLink?(found)

        case .left:
            log("disconnected")
            battery = nil
            Main.cancel(rereadTimer)
            worker.async { [self] in closeLinks() }
            onLink?(nil)
            if pendingConnect != nil {
                // It left before the connect was announced, so announce neither.
                cancelPendingConnect()
                return
            }
            onDisconnect?(displayName)

        case .leaving(let until):
            log("keyboard missing; announcing it gone if still missing in \(presence.grace)s")
            Main.after(max(0, until.timeIntervalSinceNow) + 0.05) { [weak self] in self?.poll() }

        case .stayed(let missingFor):
            log(String(format: "keyboard back within %.1fs; not announced", missingFor))

        case nil:
            break
        }
    }

    /// Delays the connect HUD until this connection's battery read, so it does not show an old level.
    private func awaitBattery(isInitial: Bool) {
        pendingConnect = isInitial
        batteryTimeout = Main.after(batteryWait) { [weak self] in
            guard let self else { return }
            self.log("no battery reading after \(self.batteryWait)s; announcing without one")
            self.announceConnect(battery: nil)
        }
    }

    private func announceConnect(battery: Int?) {
        guard let isInitial = pendingConnect else { return }
        cancelPendingConnect()
        onConnect?(displayName, battery, isInitial)
    }

    private func cancelPendingConnect() {
        pendingConnect = nil
        Main.cancel(batteryTimeout)
        batteryTimeout = nil
    }

    // MARK: Battery and profile

    private func openLinks() {
        worker.async { [self] in
            closeLinks()
            guard let instance else { return }

            var error: Int32 = 0
            if let link = GattLink(instance: instance, service: Self.batteryService,
                                   characteristic: Self.batteryLevel, error: &error,
                                   onValue: { [weak self] value in Main.async { self?.received(battery: value) } }) {
                links.append(link)
                readBattery(link)
                let subscribed = link.subscribe()
                if subscribed != 0 {
                    log("battery: cannot follow it (\(hex(subscribed))); reading it every \(Int(batteryReread))s")
                    Main.async { [self] in scheduleReread(link) }
                }
            } else {
                log("battery: no Battery Service (\(hex(error)))")
            }

            if let link = GattLink(instance: instance, service: Self.profileService,
                                   characteristic: Self.profileState, error: &error,
                                   onValue: { [weak self] value in Main.async { self?.received(profile: value) } }) {
                links.append(link)
                if case .success(let value) = link.read() { Main.async { [self] in received(profile: value) } }
                let subscribed = link.subscribe()
                if subscribed != 0 { log("profile: cannot follow it (\(hex(subscribed)))") }
            } else {
                log("profile: no profile report (\(hex(error))); the firmware predates it, or Windows "
                    + "cached the keyboard's services before it had one: remove it and pair again")
            }

            if let link = GattLink(instance: instance, service: Self.profileService,
                                   characteristic: Self.profileNames, error: &error, onValue: { _ in }) {
                links.append(link)
                namesLink = link
                Main.async { [self] in canWriteNames = true }
                readNames()
            } else {
                log("profile names: not kept (\(hex(error))); the firmware predates them, or Windows "
                    + "cached the keyboard's services before it had them: remove it and pair again")
            }
        }
    }

    /// Worker only.
    private func readNames() {
        guard let namesLink else { return }
        switch namesLink.read(capacity: Self.namesCapacity) {
        case .success(let value): Main.async { [self] in received(names: value) }
        case .failure(let error): log("profile names: read failed (\(error))")
        }
    }

    func write(_ name: ProfileNameSync.Write) {
        guard canWriteNames else { return }
        log("naming profile \(name.index) \"\(name.name)\" (\(name.op == .auto ? "if unnamed" : "set"))")
        namesInFlight += 1
        let frame = [UInt8](ProfileNamesWire.write(name.op, index: name.index, name: name.name))
        worker.async { [self] in
            guard let namesLink else { return }
            let result = namesLink.write(frame)
            Main.async { [self] in
                namesInFlight = max(0, namesInFlight - 1)
                if result != 0 { log("profile names: keyboard refused profile \(name.index) (\(hex(result)))") }
                onNameWritten?(name, result == 0)
            }
            // Read the names back, since the keyboard may change them (for example, numbering one).
            readNames()
        }
    }

    /// Worker only.
    private func readBattery(_ link: GattLink) {
        switch link.read() {
        case .success(let value): Main.async { [self] in received(battery: value) }
        case .failure(let error): log("battery: read failed (\(error))")
        }
    }

    private func scheduleReread(_ link: GattLink) {
        rereadTimer = Main.after(batteryReread) { [weak self] in
            guard let self, self.presence.isPresent, !self.stopped else { return }
            self.worker.async {
                guard self.links.contains(where: { $0 === link }) else { return }
                self.readBattery(link)
            }
            self.scheduleReread(link)
        }
    }

    /// Worker only.
    private func closeLinks() {
        for link in links { link.close() }
        links.removeAll()
        namesLink = nil
        Main.async { [self] in
            canWriteNames = false
            reportedOwn = nil
            namesGeneration = nil
            namesInFlight = 0
        }
    }

    private func received(battery value: [UInt8]) {
        guard presence.isPresent, let raw = value.first else { return }
        let level = Int(raw)
        guard (0...100).contains(level) else { return log("battery out of range: \(raw)") }
        battery = level
        log("battery \(level)%")
        announceConnect(battery: level)
        onBattery?(displayName, level)
    }

    private func received(profile value: [UInt8]) {
        guard presence.isPresent, let report = Self.parseProfileState(value) else { return }
        log("profile \(report.active) active; this computer is "
            + (report.own.map { "profile \($0)" } ?? "not bonded to one"))
        reportedOwn = report.own
        onProfile?(displayName, report.active, report.own)
        // The third byte goes up on every name change. The first report only stores it.
        if value.count >= 3, value[2] != namesGeneration {
            if namesGeneration != nil { worker.async { [self] in readNames() } }
            namesGeneration = value[2]
        }
    }

    private func received(names value: [UInt8]) {
        guard presence.isPresent else { return }
        guard let names = ProfileNamesWire.parse(Data(value)) else {
            return log("profile names: malformed \(value)")
        }
        let fromDevice = ProfileNamesWire.fromDevice(Data(value))
        log("profile names: " + names.enumerated()
            .map { "\($0.offset)=\"\($0.element)\"" + (fromDevice.contains($0.offset) ? "*" : "") }
            .joined(separator: " ") + (fromDevice.isEmpty ? "" : " (* read from the device)"))
        onNames?(names, fromDevice)
    }

    /// Same as BluetoothMonitor.parseProfileState. Both 0-based, `own` nil when not bonded.
    static func parseProfileState(_ bytes: [UInt8]) -> (active: Int, own: Int?)? {
        guard bytes.count >= 2 else { return nil }
        return (Int(bytes[0]), bytes[1] == 0xFF ? nil : Int(bytes[1]))
    }
}

enum BLEProbe {
    static func run(name: String) -> Int32 {
        print("looking for a paired Bluetooth LE device called \"\(name)\"")
        var buffer = [UInt16](repeating: 0, count: 512)
        guard m0110_ble_find(name.wide, &buffer, UInt32(buffer.count)) != 0 else {
            print("  none. Pair the keyboard in Settings > Bluetooth & devices, or pass --name.")
            return 1
        }
        let instance = String(wide: buffer)
        print("  \(instance)")

        var source: Int32 = 0
        let connected = m0110_ble_connected(instance.wide, &source)
        let how = source == 1 ? "device property" : "devnode status"
        print("  connected: \(connected == 1 ? "yes" : connected == 0 ? "no" : "unknown") (\(how))")

        var error: Int32 = 0
        if let link = GattLink(instance: instance, service: WinBluetoothMonitor.batteryService,
                               characteristic: WinBluetoothMonitor.batteryLevel, error: &error,
                               onValue: { _ in }) {
            switch link.read() {
            case .success(let value): print("  battery: \(value.first.map { "\($0)%" } ?? "empty reply")")
            case .failure(let failure): print("  battery: read failed (\(failure))")
            }
            link.close()
        } else {
            print("  battery: no Battery Service (\(hex(error)))")
        }

        if let link = GattLink(instance: instance, service: WinBluetoothMonitor.profileService,
                               characteristic: WinBluetoothMonitor.profileState, error: &error,
                               onValue: { _ in }) {
            switch link.read() {
            case .success(let value):
                if let report = WinBluetoothMonitor.parseProfileState(value) {
                    print("  profile: \(report.active) active, this computer is "
                          + (report.own.map { "profile \($0)" } ?? "not bonded to one"))
                } else {
                    print("  profile: malformed report \(value)")
                }
            case .failure(let failure): print("  profile: read failed (\(failure))")
            }
            link.close()
        } else {
            print("  profile: no profile report (\(hex(error)))")
            print("    The firmware predates it, or Windows cached the keyboard's services before it")
            print("    had one: remove the keyboard in Settings and pair it again.")
        }

        if let link = GattLink(instance: instance, service: WinBluetoothMonitor.profileService,
                               characteristic: WinBluetoothMonitor.profileNames, error: &error,
                               onValue: { _ in }) {
            switch link.read(capacity: 256) {
            case .success(let value):
                if let names = ProfileNamesWire.parse(Data(value)) {
                    let fromDevice = ProfileNamesWire.fromDevice(Data(value))
                    print("  profile names: " + names.enumerated()
                        .map { "\($0.offset)=\"\($0.element)\"" + (fromDevice.contains($0.offset) ? "*" : "") }
                        .joined(separator: " ") + (fromDevice.isEmpty ? "" : " (* read from the device)"))
                } else {
                    print("  profile names: malformed \(value)")
                }
            case .failure(let failure): print("  profile names: read failed (\(failure))")
            }
            link.close()
        } else {
            print("  profile names: not kept (\(hex(error))); firmware older than the names, or a")
            print("    cached copy of the keyboard's services: remove it in Settings and pair again.")
        }
        print("  this PC would name itself \"\(DeviceName.current())\"")
        return connected == 1 ? 0 : 1
    }
}
