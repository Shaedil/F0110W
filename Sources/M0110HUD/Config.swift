import Foundation

/// Runtime settings, resolved from CLI flags then UserDefaults then defaults.
struct Config {
    var deviceName = "M0110"
    /// The low-battery HUD fires once at or below this percentage.
    var lowThreshold = 20
    /// The alert rearms once the battery climbs back to this percentage.
    var rearmThreshold = 30
    /// Announce each drop through a multiple of this. 0 turns milestones off.
    var batteryMilestone = 10
    /// Seconds the HUD stays fully visible before fading. Long because it mostly shows on
    /// wake from sleep, and shorter holds ended before the user looked up.
    var hudDuration = 7.0
    var showDisconnect = true
    /// Seconds the keyboard must stay gone before a disconnect is announced. The link drops
    /// and recovers in under 2 s several times a day.
    var disconnectGrace = 3.0
    /// No HUD for a keyboard already connected at launch.
    var suppressInitial = false
    var previewOnly = false
    /// Flip the app's appearance under a visible HUD to test live theme changes.
    var themeCycle = false
    var studioProbe = false
    /// Off by default since the app is a menu bar agent.
    var openWindow = false
    var snapshotPath: String?
    var boardSnapshotPath: String?
    var stageSnapshotPath: String?
    var snapshotPane: String?
    /// "HH:MM" today for the snapshot's sky. Nil uses the current time.
    var snapshotTime: String?
    var verbose = false
    /// Multiplies every HUD dimension.
    var scale = 1.0
    var insetX = 110.0
    var insetY = 6.0
    /// "light" or "dark" to override the system, for checking both themes.
    var appearance: String? = nil
    /// Vibrancy material name; see HUDController.material(named:).
    var material = "toolTip"
    /// 0...1, where 1 is full vibrancy. Nil follows System Settings (see SystemTransparency).
    var transparency: Double? = nil
    var testHUD = false
    /// False keeps the clipboard bridge from starting. The Settings switch only pauses it.
    var clipboard = true
    /// Debug panel that drives the HUD by hand, with no Bluetooth or clipboard (tools/hud-dev.sh).
    var debug = false
    /// Main window on fixture data, with no Bluetooth, Studio link or HUD (tools/ui-dev.sh).
    var uiDev = false

    static func resolve(_ args: [String]) -> Config {
        var c = Config()
        let d = UserDefaults.standard

        if let n = d.string(forKey: "deviceName"), !n.isEmpty { c.deviceName = n }
        if d.object(forKey: "lowThreshold") != nil { c.lowThreshold = d.integer(forKey: "lowThreshold") }
        if d.object(forKey: "rearmThreshold") != nil { c.rearmThreshold = d.integer(forKey: "rearmThreshold") }
        if d.object(forKey: "batteryMilestone") != nil { c.batteryMilestone = d.integer(forKey: "batteryMilestone") }
        if d.object(forKey: "hudDuration") != nil { c.hudDuration = d.double(forKey: "hudDuration") }
        if d.object(forKey: "showDisconnect") != nil { c.showDisconnect = d.bool(forKey: "showDisconnect") }
        if d.object(forKey: "disconnectGrace") != nil { c.disconnectGrace = d.double(forKey: "disconnectGrace") }
        if d.object(forKey: "suppressInitial") != nil { c.suppressInitial = d.bool(forKey: "suppressInitial") }
        if d.object(forKey: "scale") != nil { c.scale = d.double(forKey: "scale") }
        if d.object(forKey: "insetX") != nil { c.insetX = d.double(forKey: "insetX") }
        if d.object(forKey: "insetY") != nil { c.insetY = d.double(forKey: "insetY") }
        if let m = d.string(forKey: "material"), !m.isEmpty { c.material = m }
        if d.object(forKey: "transparency") != nil { c.transparency = d.double(forKey: "transparency") }

        var it = args.makeIterator()
        _ = it.next() // executable path
        while let arg = it.next() {
            switch arg {
            case "--name":            if let v = it.next() { c.deviceName = v }
            case "--low":             if let v = it.next(), let n = Int(v) { c.lowThreshold = n }
            case "--rearm":           if let v = it.next(), let n = Int(v) { c.rearmThreshold = n }
            case "--milestone":       if let v = it.next(), let n = Int(v) { c.batteryMilestone = n }
            case "--duration":        if let v = it.next(), let n = Double(v) { c.hudDuration = n }
            case "--no-disconnect":   c.showDisconnect = false
            case "--disconnect-grace": if let v = it.next(), let n = Double(v), n >= 0 { c.disconnectGrace = n }
            case "--no-initial":      c.suppressInitial = true
            case "--scale":           if let v = it.next(), let n = Double(v) { c.scale = n }
            case "--inset-x":         if let v = it.next(), let n = Double(v) { c.insetX = n }
            case "--inset-y":         if let v = it.next(), let n = Double(v) { c.insetY = n }
            case "--material":        if let v = it.next() { c.material = v }
            case "--test":            c.testHUD = true
            case "--no-clipboard":    c.clipboard = false
            case "--debug":           c.debug = true
            case "--ui-dev":          c.uiDev = true
            case "--transparency":
                if let v = it.next() {
                    if v == "auto" {
                        c.transparency = nil
                    } else if let n = Double(v), (0...1).contains(n) {
                        c.transparency = n
                    } else {
                        FileHandle.standardError.write("--transparency must be 0..1 or auto\n".data(using: .utf8)!)
                        exit(2)
                    }
                }
            case "--appearance":
                if let v = it.next() {
                    guard ["light", "dark", "auto"].contains(v) else {
                        FileHandle.standardError.write("--appearance must be light, dark, or auto\n".data(using: .utf8)!)
                        exit(2)
                    }
                    c.appearance = v == "auto" ? nil : v
                }
            case "--preview":         c.previewOnly = true
            case "--theme-cycle":     c.themeCycle = true
            case "--studio-probe":    c.studioProbe = true
            case "--window":          c.openWindow = true
            case "--snapshot":        if let v = it.next() { c.snapshotPath = v }
            case "--board-snapshot":  if let v = it.next() { c.boardSnapshotPath = v }
            case "--stage-snapshot":  if let v = it.next() { c.stageSnapshotPath = v }
            case "--snapshot-pane":   if let v = it.next() { c.snapshotPane = v }
            case "--snapshot-time":   if let v = it.next() { c.snapshotTime = v }
            case "-v", "--verbose":   c.verbose = true
            case "-h", "--help":      Config.printUsage(); exit(0)
            default:
                FileHandle.standardError.write("Unknown option: \(arg)\n".data(using: .utf8)!)
                Config.printUsage()
                exit(2)
            }
        }

        // A rearm threshold below the trigger would latch the alert off forever.
        if c.rearmThreshold <= c.lowThreshold { c.rearmThreshold = c.lowThreshold + 10 }
        c.scale = min(max(c.scale, 0.5), 2.5)
        return c
    }

    static func printUsage() {
        print("""
        M0110HUD: connect/disconnect and low-battery HUD for a BLE keyboard.

          --name <str>      Bluetooth device name to watch (default: M0110)
          --low <pct>       low-battery trigger, once per descent (default: 20)
          --rearm <pct>     level the battery must return to before re-alerting (default: 30)
          --milestone <pct> announce each drop through a multiple of this (default: 10;
                            0 disables, leaving only the low-battery alert)
          --duration <sec>  how long the HUD stays visible (default: 7)
          --no-disconnect   don't show a HUD when the keyboard disconnects
          --disconnect-grace <sec>  how long the keyboard must stay gone before
                            a disconnect is announced; shorter drops are
                            ignored (default: 3; 0 announces every drop)
          --no-initial      stay quiet if the keyboard is already connected at launch
          --scale <factor>  resize the whole HUD (default 1.0; try 0.85 or 1.2)
          --inset-x <pt>    inset of the right edge from the screen edge (default 110)
          --inset-y <pt>    gap below the menu bar (default 6)
          --appearance <a>  force light|dark instead of following the system
          --transparency <n> HUD transparency as 0..1, 1 being full vibrancy;
                            default "auto" follows System Settings (Accessibility
                            > Display > Reduce transparency)
          --test            show one sample HUD for the full duration, then quit
          --no-clipboard    don't carry the clipboard to and from the keyboard
          --debug           open a panel that walks the HUD through every state by
                            hand; no Bluetooth needed (see tools/hud-dev.sh)
          --ui-dev          open the window on sample keymap data; no keyboard
                            needed (see tools/ui-dev.sh)
          --material <m>    vibrancy material (popover, hudWindow, menu, sidebar,
                            headerView, windowBackground, contentBackground,
                            underWindowBackground, fullScreenUI, toolTip, titlebar)
          --window          open the editor window at launch instead of waiting
                            for the menu bar item
          --snapshot <path> render the UI offscreen to a PNG and exit
          --snapshot-pane <n> which pane to render (Keys, Settings, ...)
          --snapshot-time <HH:MM>  the time of day whose sky the snapshot's
                            colours follow (default: now)
          --board-snapshot <path>  render the HUD's spinning 3D board to a PNG
                            strip, one frame per sixth of a turn, and exit
          --stage-snapshot <path>  render the window's 3D board at each pane's
                            focus to a PNG grid, and exit
          --studio-probe    check the ZMK Studio RPC link (USB, then Bluetooth) and exit
          --preview         show a sample HUD and quit; no Bluetooth needed
          -v, --verbose     log state transitions to stdout
          -h, --help        this text
        """)
    }
}
