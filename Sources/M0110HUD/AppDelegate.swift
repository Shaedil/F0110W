import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config: Config
    /// Held for the lifetime of the app: it owns the accessibility observer
    /// that keeps a live HUD in step with System Settings.
    private let transparency: SystemTransparency
    private let hud: HUDController
    private var monitor: BluetoothMonitor?
    private let keyboard = KeyboardController()
    private var statusItem: StatusItemController?
    private var connectionWatch: AnyCancellable?

    private static func summary(for state: KeyboardController.Connection) -> String {
        switch state {
        case .disconnected: return "Not connected"
        case .connecting: return "Looking for the keyboard..."
        case .connected(let via, let device): return "\(device) via \(via)"
        case .failed(let why): return String(why.prefix(60))
        }
    }
    private var mainWindow: MainWindowController?

    /// Persisted so a relaunch on an already-low battery doesn't re-nag.
    private var lowAlertArmed: Bool {
        get { UserDefaults.standard.object(forKey: "lowAlertArmed") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "lowAlertArmed") }
    }

    /// The last milestone announced, persisted for the same reason: a relaunch
    /// should not re-announce a level the user has already been told about.
    private var lastMilestone: Int? {
        get { UserDefaults.standard.object(forKey: "lastMilestone") as? Int }
        set { UserDefaults.standard.set(newValue, forKey: "lastMilestone") }
    }

    init(config: Config) {
        self.config = config
        let transparency = SystemTransparency(override: config.transparency,
                                              verbose: config.verbose)
        self.transparency = transparency
        self.hud = HUDController(duration: config.hudDuration,
                                 lowThreshold: config.lowThreshold,
                                 metrics: HUDMetrics(scale: config.scale,
                                                     insetX: config.insetX,
                                                     insetY: config.insetY),
                                 appearance: config.appearance,
                                 material: config.material,
                                 transparency: transparency)
        super.init()
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

        // Rasterise the board art now rather than when the keyboard connects.
        // It is one main-thread render either way; at launch nobody is waiting
        // on it, and at connect time it sits directly in front of the HUD.
        BoardArt.warm(pixelsWide: SpinningBoardView.texturePixels,
                      colorScheme: NSApp.effectiveAppearance
                          .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light)

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
        connectionWatch = keyboard.$connection.receive(on: RunLoop.main).sink { [weak self] state in
            self?.statusItem?.connectionSummary = Self.summary(for: state)
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
            guard let self else { return }
            if isInitial && self.config.suppressInitial { return }
            self.hud.show(kind: .connected, name: name, battery: battery)
        }
        m.onDisconnect = { [weak self] name in
            guard let self, self.config.showDisconnect else { return }
            self.hud.show(kind: .disconnected, name: name, battery: nil)
        }
        m.onBattery = { [weak self] name, level in
            self?.handleBattery(name: name, level: level)
        }
        monitor = m
    }

    private func handleBattery(name: String, level: Int) {
        // The BAS read lands shortly after connect; fill it into the live HUD.
        hud.updateBatteryIfVisible(kind: .connected, name: name, battery: level)

        if lowAlertArmed, level <= config.lowThreshold {
            lowAlertArmed = false
            hud.show(kind: .lowBattery, name: name, battery: level)
        } else if !lowAlertArmed, level >= config.rearmThreshold {
            lowAlertArmed = true
        }

        announceMilestone(name: name, level: level)
    }

    /// Show a HUD each time the level drops through a milestone.
    ///
    /// The low-battery alert fires once per descent, which on a 10 Ah cell is
    /// roughly never, so it was the only battery notification and it almost
    /// never appeared. Milestones give the ordinary discharge something to say.
    ///
    /// The reported percentage is not state of charge: it is a linear voltage
    /// curve at ~7.5 mV per point, so load alone moves it several points either
    /// way. Hence the guards:
    ///
    ///   * descending only: a level climbing back through a milestone rearms
    ///     it without announcing it
    ///   * a rearm margin: the level must recover well past a milestone before
    ///     that milestone can fire again, so jitter around the boundary cannot
    ///     produce a burst
    private func announceMilestone(name: String, level: Int) {
        let step = config.batteryMilestone
        guard step > 0 else { return }

        // The highest milestone at or below the current level.
        let crossed = (level / step) * step
        guard crossed > 0, crossed < 100 else { return }

        if let last = lastMilestone {
            guard crossed < last else {
                // Recovering. Only rearm once it is clear of the boundary, so a
                // level hovering on it does not toggle.
                if crossed > last + step { lastMilestone = crossed }
                return
            }
        }
        lastMilestone = crossed
        hud.show(kind: level <= config.lowThreshold ? .lowBattery : .connected,
                 name: name, battery: level)
    }

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
