import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, AnnouncerMemory {
    var config: Config {
        didSet { announcer.config = config }
    }
    /// Kept for the app's lifetime because it owns the observer that follows System Settings.
    let transparency: SystemTransparency
    private(set) var hud: HUDController
    private var debugPanel: DebugPanelController?
    /// Debug runs use their own defaults domain so they never change the real app's alert state.
    private let state: UserDefaults
    private var monitor: BluetoothMonitor?
    private var clipboard: ClipboardBridge?
    private let keyboard = KeyboardController()
    private var statusItem: StatusItemController?
    private var connectionWatch: AnyCancellable?

    private var mainWindow: MainWindowController?
    private lazy var announcer = Announcer(config: config, memory: self)

    var lowAlertArmed: Bool {
        get { state.object(forKey: "lowAlertArmed") as? Bool ?? true }
        set { state.set(newValue, forKey: "lowAlertArmed") }
    }

    var lastMilestone: Int? {
        get { state.object(forKey: "lastMilestone") as? Int }
        set { state.set(newValue, forKey: "lastMilestone") }
    }

    var lastConnectAt: Date? {
        get { state.object(forKey: "lastConnectAt") as? Date }
        set { state.set(newValue, forKey: "lastConnectAt") }
    }
    var lastDisconnectAt: Date? {
        get { state.object(forKey: "lastDisconnectAt") as? Date }
        set { state.set(newValue, forKey: "lastDisconnectAt") }
    }

    var lastBattery: Int? {
        get { state.object(forKey: "lastBattery") as? Int }
        set { state.set(newValue, forKey: "lastBattery") }
    }

    var diedAnnounced: Bool {
        get { state.bool(forKey: "diedAnnounced") }
        set { state.set(newValue, forKey: "diedAnnounced") }
    }

    /// Nil until read on this connect, and always nil on firmware that does not store names.
    private var keyboardNames: [String]?
    /// Indexes of the names the keyboard read from the devices themselves.
    private var keyboardNamesFromDevice: Set<Int> = []
    private let names = ProfileNameStore.shared
    /// This Mac's name for its own profile, e.g. "MacBook Air M4".
    private lazy var deviceName = DeviceName.current()
    private var nameEditWatch: NSObjectProtocol?
    private var nameEditSync: DispatchWorkItem?

    init(config: Config) {
        self.config = config
        let transparency = SystemTransparency(override: config.transparency,
                                              verbose: config.verbose)
        self.transparency = transparency
        self.hud = Self.makeHUD(config: config, transparency: transparency)
        self.state = config.debug
            ? UserDefaults(suiteName: "com.shaedil.m0110hud.debug") ?? .standard
            : .standard
        super.init()
    }

    private static func makeHUD(config: Config, transparency: SystemTransparency) -> HUDController {
        HUDController(duration: config.hudDuration,
                      lowThreshold: config.lowThreshold,
                      metrics: HUDMetrics(scale: config.scale,
                                          insetX: config.insetX,
                                          insetY: config.insetY),
                      appearance: config.appearance,
                      material: config.material,
                      transparency: transparency)
    }

    /// Metrics, material and appearance are fixed when a panel is made, so a live change needs a new HUD.
    func rebuildHUD() {
        let pinned = hud.pinned
        let onShow = hud.onShow
        let onMoveBack = hud.onMoveBack
        let styles = hud.styles
        let forceReduceMotion = hud.forceReduceMotion
        hud.tearDown()
        hud = Self.makeHUD(config: config, transparency: transparency)
        hud.pinned = pinned
        hud.onShow = onShow
        hud.onMoveBack = onMoveBack
        hud.styles = styles
        hud.forceReduceMotion = forceReduceMotion
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// An `.accessory` app has no app menu (no Cmd-Q or Edit shortcuts) and no Dock icon,
    /// so the app is `.regular` while the window is open.
    @objc private func openWindow() {
        installMainMenu()
        NSApp.setActivationPolicy(.regular)

        if mainWindow == nil {
            let window = MainWindowController(controller: keyboard)
            window.onClose = { [weak self] in
                // Deferred because the policy cannot change while the window is still closing.
                DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
                self?.mainWindow = nil
            }
            mainWindow = window
        }
        mainWindow?.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showSampleHUD() {
        hud.show(kind: .connected,
                 name: keyboard.connection.isConnected ? config.deviceName : config.deviceName,
                 battery: nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bluetooth discovery picks the peripheral by name, so it needs the name the HUD watches for.
        keyboard.deviceName = config.deviceName
        DebugLog.shared.echo = config.verbose
        DebugLog.shared.persists = !(config.debug || config.uiDev || config.previewOnly)

        // Render the board art at launch. Doing it on connect would delay the HUD.
        BoardArt.warm(pixelsWide: SpinningBoardView.texturePixels,
                      colorScheme: NSApp.effectiveAppearance
                          .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light)

        if config.debug {
            runDebug()
            return
        }
        if config.uiDev {
            runUIDev()
            return
        }

        let info = Bundle.main.infoDictionary
        DebugLog.shared.add(.app, "started: version "
            + "\(info?["CFBundleShortVersionString"] as? String ?? "?") "
            + "(\(info?["CFBundleVersion"] as? String ?? "?")), "
            + "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), "
            + "watching for \"\(config.deviceName)\"")

        statusItem = StatusItemController(
            onOpenWindow: { [weak self] in self?.openWindow() },
            onShowHUD: { [weak self] in self?.showSampleHUD() })

        if config.openWindow {
            openWindow()
        }

        statusItem?.model.name = config.deviceName
        connectionWatch = keyboard.$connection.receive(on: RunLoop.main).sink { [weak self] state in
            self?.statusItem?.model.editor = state
        }

        if config.testHUD {
            runTestHUD()
            return
        }
        if config.themeCycle {
            runThemeCycle()
            return
        }
        if config.previewOnly {
            runPreview()
            return
        }

        let m = BluetoothMonitor(config: config)
        m.onConnect = { [weak self] name, battery, isInitial in
            self?.clipboard?.keyboardReconnected()
            self?.handleConnect(name: name, battery: battery, isInitial: isInitial)
        }
        m.onDisconnect = { [weak self] name in
            self?.handleDisconnect(name: name)
        }
        m.onBattery = { [weak self] name, level in
            self?.handleBattery(name: name, level: level)
        }
        m.onProfile = { [weak self] name, active, own in
            self?.handleProfileSwitch(name: name, active: active, own: own)
        }
        m.onNames = { [weak self] names, fromDevice in
            self?.handleProfileNames(names, fromDevice: fromDevice)
        }
        m.onNameWritten = { [weak self] write, _ in
            self?.names.answered(write)
        }
        monitor = m
        // Settings renames on every keystroke, so wait for typing to stop before sending.
        nameEditWatch = NotificationCenter.default.addObserver(
            forName: .profileNameEdited, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.nameEditSync?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.syncProfileNames() }
            self.nameEditSync = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }

        if config.clipboard {
            clipboard = ClipboardBridge(deviceName: config.deviceName) { message in
                DebugLog.shared.add(.clipboard, message)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let clipboard else { return }
        clipboard.shutdown()
        // The goodbye is a queued Bluetooth write. Give it time to go out before exiting.
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }

    // The debug panel calls these handlers directly, so it shows what the real link would.

    func handleConnect(name: String, battery: Int?, isInitial: Bool, now: Date = Date()) {
        statusItem?.model.linked = true
        statusItem?.model.battery = battery
        show(announcer.connect(battery: battery, isInitial: isInitial, now: now), name: name)
    }

    func isArrival(at now: Date) -> Bool { announcer.isArrival(at: now) }

    func handleDisconnect(name: String, now: Date = Date()) {
        keyboardNames = nil
        statusItem?.model.linked = false
        statusItem?.model.profile = nil
        show(announcer.disconnect(now: now), name: name)
    }

    func handleProfileSwitch(name: String, active: Int, own: Int?) {
        let announcement = announcer.profileSwitch(active: active, own: own)
        statusItem?.model.profile = ProfileState(active: active, own: announcer.ownProfile)
        if let move = announcer.lastMove { DebugLog.shared.add(.app, move.explanation) }
        show(announcement, name: name)
        // The own profile may only be known now.
        syncProfileNames()
    }

    func handleProfileNames(_ keyboard: [String], fromDevice: Set<Int> = []) {
        keyboardNames = keyboard
        keyboardNamesFromDevice = fromDevice
        names.carryOverIfNeeded(keyboard: keyboard)
        syncProfileNames()
    }

    /// Sends renames made here, plus this Mac's name if its profile has none, and caches the
    /// keyboard's names. Skips while a write is in flight, since its reply calls back here.
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

    func handleBattery(name: String, level: Int) {
        statusItem?.model.battery = level
        // The BAS read arrives shortly after connect, so update a HUD that is already showing.
        hud.updateBatteryIfVisible(name: name, battery: level)
        for announcement in announcer.battery(level: level) {
            show(announcement, name: name)
        }
    }

    private func show(_ announcement: Announcement?, name: String) {
        guard let announcement else { return }
        hud.show(kind: announcement.kind, name: name, battery: announcement.battery,
                 detail: announcement.detail)
    }

    func resetHistory() { announcer.resetHistory() }

    /// Built in code since there is no nib. Without it a `.regular` app cannot quit or reopen its window.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About M0110", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Reconnect Keyboard",
                        action: #selector(reconnect), keyEquivalent: "r")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide M0110", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit M0110", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Configuration",
                           action: #selector(openWindow), keyEquivalent: "0")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc private func reconnect() { keyboard.connect() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow() }
        return true
    }

    /// Shows the debug panel instead of the monitor, clipboard and menu bar item. Runs as a
    /// regular app so the panel gets focus and Cmd-Q quits.
    private func runDebug() {
        installMainMenu()
        NSApp.setActivationPolicy(.regular)
        // Launch callbacks arrive on the main thread.
        MainActor.assumeIsolated {
            let panel = DebugPanelController(app: self)
            debugPanel = panel
            panel.show()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Reopens on the last pane so a relaunch from tools/ui-dev.sh lands on the pane being edited.
    private func runUIDev() {
        let defaults = UserDefaults(suiteName: "com.shaedil.m0110hud.debug")
        let key = "uiDev.pane"
        keyboard.loadPreviewFixture()
        installMainMenu()
        NSApp.setActivationPolicy(.regular)
        let window = MainWindowController(
            controller: keyboard,
            initialPane: defaults?.string(forKey: key).flatMap(Pane.init(rawValue:)) ?? .keys,
            onPaneChange: { defaults?.set($0.rawValue, forKey: key) })
        window.onClose = { NSApp.terminate(nil) }
        mainWindow = window
        window.show()

        MainActor.assumeIsolated {
            let item = StatusItemController(onOpenWindow: { window.show() },
                                            onShowHUD: { [weak self] in self?.showSampleHUD() })
            item.model.name = config.deviceName
            item.model.linked = true
            item.model.battery = 72
            item.model.profile = ProfileState(active: 0, own: 0)
            item.model.editor = keyboard.connection
            statusItem = item
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Setting `NSApp.appearance` triggers the same update as a system theme change, so this
    /// tests the live path without touching System Settings.
    private func runThemeCycle() {
        hud.show(kind: .connected, name: config.deviceName, battery: 76)
        let steps: [(TimeInterval, NSAppearance.Name?)] = [
            (3, .aqua),
            (6, .darkAqua),
            (9, nil),          // follow the system
        ]
        for (delay, name) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApp.appearance = name.flatMap { NSAppearance(named: $0) }
                print("[theme] app appearance -> \(name?.rawValue ?? "system")")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { NSApp.terminate(nil) }
    }

    /// `--test`: one HUD for the configured time, then quit.
    private func runTestHUD() {
        hud.show(kind: .connected, name: config.deviceName, battery: 76)
        // The fade runs after the hold, so wait for both before quitting.
        DispatchQueue.main.asyncAfter(deadline: .now() + config.hudDuration + 1.2) {
            NSApp.terminate(nil)
        }
    }

    private func runPreview() {
        let name = config.deviceName
        let step = config.hudDuration + 0.6
        hud.show(kind: .connected, name: name, battery: 25)
        DispatchQueue.main.asyncAfter(deadline: .now() + step) { [self] in
            hud.show(kind: .lowBattery, name: name, battery: config.lowThreshold - 5)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step * 2) { [self] in
            hud.show(kind: .disconnected, name: name, battery: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step * 3) {
            NSApp.terminate(nil)
        }
    }
}
