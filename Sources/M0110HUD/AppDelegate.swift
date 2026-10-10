import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, AnnouncerMemory {
    /// Mutable so the debug panel can change thresholds and the HUD's look
    /// while the app runs.
    var config: Config {
        didSet { announcer.config = config }
    }
    /// Held for the lifetime of the app: it owns the accessibility observer
    /// that keeps a live HUD in step with System Settings.
    let transparency: SystemTransparency
    private(set) var hud: HUDController
    private var debugPanel: DebugPanelController?
    /// Where the alert latch and milestone live. Debug runs get their own
    /// domain, so walking the state machine by hand never disturbs the real
    /// app's memory of what it has already announced.
    private let state: UserDefaults
    private var monitor: BluetoothMonitor?
    private var clipboard: ClipboardBridge?
    private let keyboard = KeyboardController()
    private var statusItem: StatusItemController?
    private var connectionWatch: AnyCancellable?

    private var mainWindow: MainWindowController?
    /// Decides what each event shows, from the state below; this class only
    /// puts it on screen.
    private lazy var announcer = Announcer(config: config, memory: self)

    /// Persisted so a relaunch on an already-low battery doesn't re-nag.
    var lowAlertArmed: Bool {
        get { state.object(forKey: "lowAlertArmed") as? Bool ?? true }
        set { state.set(newValue, forKey: "lowAlertArmed") }
    }

    /// The last milestone announced, persisted for the same reason: a relaunch
    /// should not re-announce a level the user has already been told about.
    var lastMilestone: Int? {
        get { state.object(forKey: "lastMilestone") as? Int }
        set { state.set(newValue, forKey: "lastMilestone") }
    }

    /// When the keyboard last connected and last left, for telling the first
    /// connect of the day from the rest. Persisted: the gap that makes an
    /// arrival is usually a night, and the app may well restart inside it.
    var lastConnectAt: Date? {
        get { state.object(forKey: "lastConnectAt") as? Date }
        set { state.set(newValue, forKey: "lastConnectAt") }
    }
    var lastDisconnectAt: Date? {
        get { state.object(forKey: "lastDisconnectAt") as? Date }
        set { state.set(newValue, forKey: "lastDisconnectAt") }
    }

    /// The last level the keyboard reported. BluetoothMonitor forgets it on
    /// disconnect, but that is exactly when it decides between "disconnected"
    /// and "died".
    var lastBattery: Int? {
        get { state.object(forKey: "lastBattery") as? Int }
        set { state.set(newValue, forKey: "lastBattery") }
    }

    /// Set once the empty-battery HUD has been shown, until the battery is
    /// charged again, so a level bouncing on 0 does not repeat it.
    var diedAnnounced: Bool {
        get { state.bool(forKey: "diedAnnounced") }
        set { state.set(newValue, forKey: "diedAnnounced") }
    }

    /// The profiles' names as the keyboard last gave them, this connect. Nil
    /// until read, and always on firmware that does not keep them.
    private var keyboardNames: [String]?
    private let names = ProfileNameStore.shared
    /// What this Mac offers as its own profile's name, e.g. "MacBook Air M4".
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

    /// Replace the HUD with one built from the current config. The metrics,
    /// material and appearance are fixed when a panel is made, so changing any
    /// of them live means starting over. Pinning, styles, the Reduce Motion override and the show hook carry over.
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

    /// Closing the window leaves the HUD running in the background.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Show the editor, promoting the app to a normal one for as long as it is
    /// open.
    ///
    /// An `.accessory` app can show a window, but it gets no application menu:
    /// no ⌘Q, no Edit shortcuts, no Dock entry to bring it back once it is
    /// behind something. Switching to `.regular` while a window is up and back
    /// afterwards keeps the menu bar presence honest: a Dock icon exactly when
    /// there is a window to return to.
    @objc private func openWindow() {
        installMainMenu()
        NSApp.setActivationPolicy(.regular)

        if mainWindow == nil {
            let window = MainWindowController(controller: keyboard)
            window.onClose = { [weak self] in
                // Deferred: the policy cannot change while the window is still
                // in the middle of closing.
                DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
                self?.mainWindow = nil
            }
            mainWindow = window
        }
        mainWindow?.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Summon the HUD on demand.
    private func showSampleHUD() {
        hud.show(kind: .connected,
                 name: keyboard.connection.isConnected ? config.deviceName : config.deviceName,
                 battery: nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The Bluetooth discovery route picks its peripheral by name, so it
        // needs the same name the HUD watches for.
        keyboard.deviceName = config.deviceName
        DebugLog.shared.echo = config.verbose
        DebugLog.shared.persists = !(config.debug || config.uiDev || config.previewOnly)

        // Rasterise the board art now rather than when the keyboard connects.
        // It is one main-thread render either way; at launch nobody is waiting
        // on it, and at connect time it sits directly in front of the HUD.
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

        // The app lives in the menu bar. It has no Dock icon and opens no
        // window until asked, so this is its only permanent presence.
        statusItem = StatusItemController(
            onOpenWindow: { [weak self] in self?.openWindow() },
            onShowHUD: { [weak self] in self?.showSampleHUD() })

        if config.openWindow {
            openWindow()
        }

        // Mirror the link state into the menu, so the menu bar can answer
        // "is it connected?" without opening the window.
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
        m.onNames = { [weak self] names in
            self?.handleProfileNames(names)
        }
        m.onNameWritten = { [weak self] write, _ in
            self?.names.answered(write)
        }
        monitor = m
        // Typing in Settings renames on every keystroke; send the name once
        // the typing stops.
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
        // The goodbye is a queued Bluetooth write; give it a moment to leave
        // before the process does.
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }

    // The events the keyboard reports. The debug panel calls these directly,
    // so what it shows is what the real link would produce. What each one
    // announces is the Announcer's call; see Announcer.swift.

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
        // Which profile is this Mac may only now be known, and with it which
        // name to fill in.
        syncProfileNames()
    }

    /// The keyboard's names, read on connect and again whenever one changes.
    func handleProfileNames(_ keyboard: [String]) {
        keyboardNames = keyboard
        names.carryOverIfNeeded(keyboard: keyboard)
        syncProfileNames()
    }

    /// Sends the keyboard the renames made here and, if this Mac's profile
    /// has no name, this Mac's; then takes the keyboard's names as the copy
    /// here. Writes wait for any already sent, whose answer reads the names
    /// again and comes back here.
    private func syncProfileNames() {
        guard let keyboard = keyboardNames else { return }
        names.cache(keyboard)
        guard let monitor, monitor.canWriteNames, !monitor.isWritingNames else { return }
        for write in ProfileNameSync.writes(keyboard: keyboard, pending: names.pending,
                                            own: monitor.reportedOwn, deviceName: deviceName) {
            monitor.write(write)
        }
    }

    func handleBattery(name: String, level: Int) {
        statusItem?.model.battery = level
        // The BAS read lands shortly after connect; fill it into the live HUD.
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

    /// Forget the day and battery history, for the debug panel.
    func resetHistory() { announcer.resetHistory() }

    /// A programmatic menu bar, since this app has no nib. Without it a
    /// `.regular` app has no way to quit or reopen its window.
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

    /// Reopen the window when the Dock icon is clicked with no window showing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow() }
        return true
    }

    /// The debug panel, in place of the monitor, the clipboard and the menu
    /// bar item. A regular app for the duration, so the panel takes focus and
    /// ⌘Q quits it.
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

    /// Open the window on the preview fixture, back on whichever pane was last
    /// showing, so a relaunch from tools/ui-dev.sh lands where the edit is.
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

        // The menu too, on sample values, so its design can be worked on here.
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

    /// Show one HUD, then flip the app's appearance beneath it. Overriding
    /// `NSApp.appearance` fires the same propagation a system theme change does,
    /// so this exercises the live path without altering System Settings.
    private func runThemeCycle() {
        hud.show(kind: .connected, name: config.deviceName, battery: 76)
        let steps: [(TimeInterval, NSAppearance.Name?)] = [
            (3, .aqua),        // light
            (6, .darkAqua),    // dark
            (9, nil),          // back to following the system
        ]
        for (delay, name) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApp.appearance = name.flatMap { NSAppearance(named: $0) }
                print("[theme] app appearance -> \(name?.rawValue ?? "system")")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { NSApp.terminate(nil) }
    }

    /// One HUD, held for the configured duration, then quit: what `--test` is
    /// for. Unlike `--preview` it shows a single notification, so the hold time
    /// and the transparency can be read off it without three of them going by.
    private func runTestHUD() {
        hud.show(kind: .connected, name: config.deviceName, battery: 76)
        // The fade runs after the hold, so wait out both before quitting.
        DispatchQueue.main.asyncAfter(deadline: .now() + config.hudDuration + 1.2) {
            NSApp.terminate(nil)
        }
    }

    /// Walk through each HUD state so the look can be checked without hardware.
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
