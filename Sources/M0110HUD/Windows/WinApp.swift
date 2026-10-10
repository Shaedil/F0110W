import CM0110Win
import Foundation

/// The Windows app: a tray icon in place of the menu bar item, the HUD, and
/// the keyboard's events between them. What each event shows is the
/// Announcer's call, exactly as on the Mac.
final class WinApp {
    /// For the C callbacks, which carry no context.
    static var shared: WinApp?

    /// The flags and settings in force. Settings changed in the window apply
    /// at once, here and in the HUD and announcer.
    private var config: Config
    private var settings = WinSettings.load()
    private let hud: WinHUD
    private let memory = FileMemory(url: AppFiles.state)
    private let announcer: Announcer
    private let text = GDIText()
    private var monitor: WinBluetoothMonitor?
    private let window: WinWindow
    private let keyboard = WinKeyboard()
    private var clipLink: WinClipLink?
    private let openWindowAtLaunch: Bool
    /// Off for --test and --preview, which only show a HUD.
    private var hasTray = false

    /// The profiles' names as the keyboard last gave them, this connect. Nil
    /// until read, and always on firmware that does not keep them.
    private var keyboardNames: [String]?
    /// Which of those the keyboard read from the devices themselves.
    private var keyboardNamesFromDevice: Set<Int> = []
    /// This PC's side of the names, kept in settings.json.
    private lazy var names = ProfileNameStore(
        load: { [unowned self] in
            let saved = settings.profileNames ?? []
            let pending = settings.profileNamesPending ?? [:]
            return ProfileNameStore.State(
                names: (0..<ProfileNames.count).map { saved.indices.contains($0) ? saved[$0] : "" },
                pending: Dictionary(uniqueKeysWithValues: pending.compactMap { key, value in
                    Int(key).map { ($0, value) }
                }),
                carriedOver: settings.profileNamesCarriedOver ?? false)
        },
        store: { [unowned self] state in
            settings.profileNames = state.names
            settings.profileNamesPending = state.pending.isEmpty ? nil
                : Dictionary(uniqueKeysWithValues: state.pending.map { (String($0.key), $0.value) })
            settings.profileNamesCarriedOver = state.carriedOver
            saveSettings()
        })
    /// What this PC offers as its own profile's name, e.g. "Windows 11 PC".
    private lazy var deviceName = DeviceName.current()
    /// Typing in the window renames on every keystroke; the name goes to the
    /// keyboard once the typing stops.
    private var nameEditSync: UInt32?

    /// What the tray shows.
    private var linked = false
    private var battery: Int?
    /// Which profile the keyboard types to: the link stays up while it types
    /// to another computer. Nil until reported, and after a disconnect.
    private var profile: ProfileState?

    /// The name the app is registered under in HKCU\...\Run.
    static let runName = "M0110HUD"

    init(config: Config) {
        self.config = config
        openWindowAtLaunch = config.openWindow
        window = WinWindow(verbose: config.verbose)
        hud = WinHUD(config: config)
        announcer = Announcer(config: config, memory: memory)
        announcer.profileName = { [unowned self] in self.settings.profileName($0) }
        keyboard.deviceName = config.deviceName
        keyboard.verbose = config.verbose
    }

    func run() -> Int32 {
        let oneShot = config.testHUD || config.previewOnly
        guard oneShot || m0110_single_instance("Local\\M0110HUD".wide) != 0 else {
            print("M0110HUD is already running.")
            return 0
        }

        var callbacks = m0110_callbacks(
            wake: { Main.drain() },
            timer: { Main.fire($0) },
            tray: { WinApp.shared?.trayClicked($0) },
            settings_changed: { WinApp.shared?.updateTray() },
            clipboard: { WinApp.shared?.clipboardChanged() })
        let status = m0110_app_init(&callbacks)
        guard status == 0 else {
            FileHandle.standardError.write("could not start: Win32 error \(status)\n".data(using: .utf8)!)
            return 1
        }
        WinApp.shared = self

        if config.testHUD {
            hud.show(kind: .connected, name: config.deviceName, battery: 76)
            Main.after(config.hudDuration + 1.2) { m0110_app_quit() }
        } else if config.previewOnly {
            runPreview()
        } else {
            hasTray = true
            updateTray()
            startMonitor()
            window.onMessage = { [weak self] type, body in self?.windowMessage(type, body) }
            window.onClosed = { [weak self] in self?.keyboard.disconnect() }
            startClipboard()
            keyboard.onChange = { [weak self] in self?.postWindowState() }
            if openWindowAtLaunch { window.open() }
            // For CI: holds the app thread once, so hang.log has something
            // to record.
            if let hang = ProcessInfo.processInfo.environment["M0110_HANG_TEST"].flatMap(Double.init) {
                Main.after(2) { Thread.sleep(forTimeInterval: hang) }
            }
        }
        let code = m0110_app_run()
        clipLink?.shutdown()
        monitor?.stop()
        return code
    }

    private func startMonitor() {
        let m = WinBluetoothMonitor(config: config)
        m.onConnect = { [weak self] name, battery, isInitial in
            self?.handleConnect(name: name, battery: battery, isInitial: isInitial)
        }
        m.onDisconnect = { [weak self] name in self?.handleDisconnect(name: name) }
        m.onBattery = { [weak self] name, level in self?.handleBattery(name: name, level: level) }
        m.onLink = { [weak self] instance in self?.clipLink?.keyboard(instance) }
        m.onProfile = { [weak self] name, active, own in
            guard let self else { return }
            let announcement = self.announcer.profileSwitch(active: active, own: own)
            if let move = self.announcer.lastMove { log(move.explanation, verbose: self.config.verbose) }
            self.profile = ProfileState(active: active, own: self.announcer.ownProfile)
            self.updateTray()
            self.show(announcement, name: name)
            // Which profile is this PC may only now be known, and with it
            // which name to fill in.
            self.syncProfileNames()
        }
        m.onNames = { [weak self] keyboard, fromDevice in
            self?.handleProfileNames(keyboard, fromDevice: fromDevice)
        }
        m.onNameWritten = { [weak self] write, _ in self?.names.answered(write) }
        monitor = m
        m.start()
    }

    /// The keyboard's names, read on connect and again whenever one changes.
    private func handleProfileNames(_ keyboard: [String], fromDevice: Set<Int>) {
        keyboardNames = keyboard
        keyboardNamesFromDevice = fromDevice
        names.carryOverIfNeeded(keyboard: keyboard)
        syncProfileNames()
    }

    /// As on the Mac: sends the keyboard the renames made here and, if this
    /// PC's profile has no name, this PC's; then takes the keyboard's names
    /// as the copy here. Writes wait for any already sent, whose answer reads
    /// the names again and comes back here.
    private func syncProfileNames() {
        guard let keyboard = keyboardNames else { return }
        names.cache(keyboard)
        guard let monitor, monitor.canWriteNames, !monitor.isWritingNames else { return }
        for write in ProfileNameSync.writes(keyboard: keyboard, pending: names.pending,
                                            own: monitor.reportedOwn, deviceName: deviceName,
                                            fromDevice: keyboardNamesFromDevice) {
            monitor.write(write)
        }
    }

    /// Walk through each HUD state, as the Mac's --preview does.
    private func runPreview() {
        let name = config.deviceName
        let step = config.hudDuration + 0.6
        hud.show(kind: .connected, name: name, battery: 25)
        Main.after(step) { [self] in hud.show(kind: .lowBattery, name: name, battery: config.lowThreshold - 5) }
        Main.after(step * 2) { [self] in hud.show(kind: .disconnected, name: name, battery: nil) }
        Main.after(step * 3) { m0110_app_quit() }
    }

    // MARK: Clipboard

    /// The keyboard's clipboard: text and small images carried to and from
    /// the other computers it switches between.
    private func startClipboard() {
        let courier = WinClipCourier(clipboard: WindowsClipboard())
        clipLink = WinClipLink(courier: courier, deviceName: config.deviceName,
                               enabled: settings.clipboardSync ?? true,
                               log: { [weak self] in log($0, verbose: self?.config.verbose ?? false) })
    }

    /// Something was copied, by any program.
    func clipboardChanged() {
        clipLink?.courier.checkClipboard()
    }

    // MARK: Events

    private func handleConnect(name: String, battery: Int?, isInitial: Bool) {
        linked = true
        self.battery = battery
        updateTray()
        show(announcer.connect(battery: battery, isInitial: isInitial), name: name)
    }

    private func handleDisconnect(name: String) {
        linked = false
        battery = nil
        profile = nil
        keyboardNames = nil
        updateTray()
        show(announcer.disconnect(), name: name)
    }

    private func handleBattery(name: String, level: Int) {
        battery = level
        updateTray()
        hud.updateBatteryIfVisible(name: name, battery: level)
        for announcement in announcer.battery(level: level) {
            show(announcement, name: name)
        }
    }

    private func show(_ announcement: Announcement?, name: String) {
        guard let announcement else { return }
        hud.show(kind: announcement.kind, name: name, battery: announcement.battery, detail: announcement.detail)
    }

    // MARK: Tray

    private var status: String {
        guard linked else { return "Not connected" }
        let connected = battery.map { "Connected, \($0)%" } ?? "Connected"
        guard let profile, let here = profile.typingHere else { return connected }
        return here ? "\(connected) \u{00B7} typing here"
            : "\(connected) \u{00B7} on \(settings.profileName(profile.active))"
    }

    func updateTray() {
        guard hasTray else { return }
        postWindowState()
        let size = Int(m0110_tray_icon_size())
        let icon = HUDArt.trayIcon(size: size, darkTaskbar: m0110_taskbar_dark() != 0, connected: linked,
                                   text: text)
        _ = m0110_tray_set(icon.bgraStraight(), Int32(size), "\(config.deviceName): \(status)".wide)
    }

    func trayClicked(_ event: Int32) {
        log("tray: \(event == 1 ? "click" : "menu")", verbose: config.verbose)
        if event == 1 {
            window.open()
        } else {
            showMenu()
        }
    }

    // MARK: Window

    private func windowMessage(_ type: String, _ body: [String: Any]) {
        switch type {
        case "ready":
            window.post(FixedState())
            postWindowState()
            // The Mac's window connects its editor when it appears.
            keyboard.connect()
        case "layout":
            if let width = body["width"] as? Int, let height = body["height"] as? Int {
                window.resize(width: width, height: height)
            }
        case "keyboard.reload": keyboard.reload()
        case "keyboard.unlockCheck": keyboard.refreshLockState()
        case "keyboard.save": keyboard.save()
        case "keyboard.discard": keyboard.discard()
        case "keyboard.rebind":
            if let layer = body["layer"] as? Int, let position = body["position"] as? Int,
               let value = (body["value"] as? NSNumber)?.uint32Value {
                keyboard.rebind(layerIndex: layer, position: position, to: value)
            }
        case "settings.set":
            if let key = body["key"] as? String { setSetting(key, body["value"]) }
        case "profiles.set":
            if let index = body["index"] as? Int, let name = body["name"] as? String,
               (0..<ProfileNames.count).contains(index) {
                // Cut to what the keyboard keeps, so what shows is what every
                // other computer will show.
                names.edit(index, name.utf8.count > ProfileNamesWire.maxBytes
                    ? ProfileNamesWire.clean(name) : name)
                Main.cancel(nameEditSync)
                nameEditSync = Main.after(0.8) { [weak self] in
                    self?.nameEditSync = nil
                    self?.syncProfileNames()
                }
            }
        default:
            log("window: unknown message \(type)", verbose: config.verbose)
        }
    }

    /// A setting from the Battery or Settings pane: saved, and in force from
    /// the next popup.
    private func setSetting(_ key: String, _ value: Any?) {
        let number = (value as? NSNumber)?.doubleValue
        let flag = (value as? NSNumber)?.boolValue
        switch key {
        case "scale": if let number { settings.scale = number; config.scale = number }
        case "insetX": if let number { settings.insetX = number; config.insetX = number }
        case "insetY": if let number { settings.insetY = number; config.insetY = number }
        case "hudDuration": if let number { settings.hudDuration = number; config.hudDuration = number }
        case "showDisconnect": if let flag { settings.showDisconnect = flag; config.showDisconnect = flag }
        case "suppressInitial": if let flag { settings.suppressInitial = flag; config.suppressInitial = flag }
        case "clipboardSync":
            if let flag {
                settings.clipboardSync = flag
                clipLink?.enabled = flag
            }
        case "lowThreshold":
            if let number { settings.lowThreshold = Int(number); config.lowThreshold = Int(number) }
        case "rearmThreshold":
            if let number { settings.rearmThreshold = Int(number); config.rearmThreshold = Int(number) }
        default:
            log("window: unknown setting \(key)", verbose: config.verbose)
            return
        }
        hud.config = config
        announcer.config = config
        saveSettings()
    }

    private func saveSettings() {
        do {
            try settings.save()
        } catch {
            log("could not save \(AppFiles.settings.path): \(error)", verbose: true)
        }
        postWindowState()
    }

    private func postWindowState() {
        guard window.isReady else { return }
        let saved = settings.profileNames ?? []
        let names = (0..<5).map { saved.indices.contains($0) ? saved[$0] : "" }
        var current = WindowState.Settings(config)
        current.clipboardSync = settings.clipboardSync ?? true
        window.post(WindowState(
            device: .init(name: config.deviceName, linked: linked, battery: battery,
                          profile: profile.map { .init(active: $0.active, own: $0.own,
                                                       name: settings.profileName($0.active)) }),
            keyboard: .init(keyboard),
            settings: current,
            profiles: names))
    }

    private func showMenu() {
        let startsAtLogin = m0110_runs_at_login(Self.runName.wide) != 0
        let items: [(String, UInt8)] = [
            ("\(config.deviceName): \(status)", 2),
            ("-", 0),
            ("Open M0110...", 0),
            ("Start at Login", startsAtLogin ? 1 : 0),
            ("-", 0),
            ("Quit M0110", 0),
        ]
        var labels: [UInt16] = items.flatMap { $0.0.wide }
        labels.append(0)
        let flags = items.map(\.1)
        let choice = m0110_menu(labels, flags)
        log("tray: menu chose \(choice == 0 ? "nothing" : items[Int(choice) - 1].0)", verbose: config.verbose)
        switch choice {
        case 3: window.open()
        case 4: _ = Self.setRunAtLogin(!startsAtLogin)
        case 6: m0110_app_quit()
        default: break
        }
    }

    /// Adds this executable to HKCU\...\Run, or takes it off. Returns the
    /// Win32 status, 0 on success.
    static func setRunAtLogin(_ on: Bool, arguments: [String] = []) -> Int32 {
        guard on else { return m0110_run_at_login(runName.wide, nil) }
        var path = [UInt16](repeating: 0, count: 4096)
        guard m0110_module_path(&path, UInt32(path.count)) > 0 else { return -1 }
        let command = ([String(wide: path)] + arguments).map { "\"\($0)\"" }.joined(separator: " ")
        return m0110_run_at_login(runName.wide, command.wide)
    }
}

/// Sent once as the page loads: what never changes.
struct FixedState: Encodable {
    var type = "fixed"
    var board = BoardJSON.m0110
    var picker = PickerGroupJSON.all
    /// The pane to open on, from M0110_WINDOW_PANE: for screenshots in CI.
    var pane = ProcessInfo.processInfo.environment["M0110_WINDOW_PANE"]
}

/// Everything the window shows that changes.
struct WindowState: Encodable {
    struct Device: Encodable {
        /// Which profile the keyboard types to; see ProfileState.
        struct Profile: Encodable {
            var active: Int
            var own: Int?
            var name: String
        }

        var name: String
        var linked: Bool
        var battery: Int?
        var profile: Profile?
    }

    struct Keyboard: Encodable {
        struct Connection: Encodable {
            var state: String
            var label: String?
            var device: String?
            var detail: String?
        }

        var connection: Connection
        var locked: Bool
        var status: String?
        var pendingEdits: Int
        var layers: [LayerJSON]

        init(_ keyboard: WinKeyboard) {
            switch keyboard.connection {
            case .disconnected: connection = Connection(state: "disconnected")
            case .connecting: connection = Connection(state: "connecting")
            case .connected(let port, let device): connection = Connection(state: "connected", label: port, device: device)
            case .failed(let reason): connection = Connection(state: "failed", detail: reason)
            }
            locked = keyboard.lockState != .unlocked
            status = keyboard.status
            pendingEdits = keyboard.pendingEdits
            // A keymap already loaded stays on show while locked, dimmed, as
            // on the Mac; the locked empty state is for a board never read.
            layers = keyboard.layers
        }
    }

    struct Settings: Encodable {
        var scale: Double
        var insetX: Double
        var insetY: Double
        var hudDuration: Double
        var showDisconnect: Bool
        var suppressInitial: Bool
        var lowThreshold: Int
        var rearmThreshold: Int
        var clipboardSync = true

        init(_ c: Config) {
            scale = c.scale
            insetX = c.insetX
            insetY = c.insetY
            hudDuration = c.hudDuration
            showDisconnect = c.showDisconnect
            suppressInitial = c.suppressInitial
            lowThreshold = c.lowThreshold
            rearmThreshold = c.rearmThreshold
        }
    }

    var type = "state"
    var device: Device
    var keyboard: Keyboard
    var settings: Settings
    var profiles: [String]
}
