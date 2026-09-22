import Foundation

/// Runtime settings, resolved from CLI flags then UserDefaults then defaults.
struct Config {
    var deviceName = "M0110"
    /// Battery percentage at or below which the low-battery HUD fires once.
    var lowThreshold = 20
    /// Percentage the battery must climb back to before the alert re-arms.
    var rearmThreshold = 30
    /// Announce the battery each time it drops through a multiple of this.
    /// Zero turns milestones off, leaving only the single low-battery alert.
    var batteryMilestone = 10
    /// Seconds the HUD stays fully visible before fading out.
    ///
    /// Seven, not the three it was: the HUD's own reason for existing is the
    /// wake-from-sleep reconnect, where the keyboard is picked up, typed on,
    /// and only answers a few seconds later. A three second hold was routinely
    /// over before the user had looked up, and seven still was.
    var hudDuration = 7.0
    var showDisconnect = true
    /// Suppress the HUD for a keyboard that was already connected at launch.
    var suppressInitial = false
    /// Show a sample HUD immediately and exit-on-nothing; for tweaking the look.
    var previewOnly = false
    /// Hold one HUD on screen and flip the app's appearance under it, to prove a
    /// live theme change reaches an already-visible panel.
    var themeCycle = false
    /// Verify the ZMK Studio RPC link from the command line, then exit.
    var studioProbe = false
    /// Open the editor window at launch. Off by default: the app is a menu bar
    /// agent, and the window is opened from there when it is wanted.
    var openWindow = false
    /// Render the UI offscreen to this path, then exit.
    var snapshotPath: String?
    /// Render the spinning 3D board offscreen to this path, then exit.
    var boardSnapshotPath: String?
    var snapshotPane: String?
    var verbose = false
    /// Multiplies every HUD dimension; 1.0 is the tuned default.
    var scale = 1.0
    /// Inset of the HUD's right edge from the right screen edge.
    var insetX = 110.0
    /// Gap between the menu bar and the top of the HUD.
    var insetY = 6.0
    /// Force the HUD's appearance instead of following the system: "light" or
    /// "dark". Mainly for checking both themes without changing System Settings.
    var appearance: String? = nil
    /// Vibrancy material name; see HUDController.material(named:).
    var material = "toolTip"
    /// Transparency of the HUD as a 0...1 level, 1 being full vibrancy. `nil`
    /// follows System Settings; see SystemTransparency.
    var transparency: Double? = nil
    /// Show one sample HUD, hold it for the full duration, then quit.
    var testHUD = false

    static func resolve(_ args: [String]) -> Config {
        var c = Config()
        let d = UserDefaults.standard

        if let n = d.string(forKey: "deviceName"), !n.isEmpty { c.deviceName = n }
        if d.object(forKey: "lowThreshold") != nil { c.lowThreshold = d.integer(forKey: "lowThreshold") }
        if d.object(forKey: "rearmThreshold") != nil { c.rearmThreshold = d.integer(forKey: "rearmThreshold") }
        if d.object(forKey: "batteryMilestone") != nil { c.batteryMilestone = d.integer(forKey: "batteryMilestone") }
        if d.object(forKey: "hudDuration") != nil { c.hudDuration = d.double(forKey: "hudDuration") }
        if d.object(forKey: "showDisconnect") != nil { c.showDisconnect = d.bool(forKey: "showDisconnect") }
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
            case "--no-initial":      c.suppressInitial = true
            case "--scale":           if let v = it.next(), let n = Double(v) { c.scale = n }
            case "--inset-x":         if let v = it.next(), let n = Double(v) { c.insetX = n }
            case "--inset-y":         if let v = it.next(), let n = Double(v) { c.insetY = n }
            case "--material":        if let v = it.next() { c.material = v }
            case "--test":            c.testHUD = true
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
            case "--snapshot-pane":   if let v = it.next() { c.snapshotPane = v }
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
          --no-initial      stay quiet if the keyboard is already connected at launch
          --scale <factor>  resize the whole HUD (default 1.0; try 0.85 or 1.2)
          --inset-x <pt>    inset of the right edge from the screen edge (default 110)
          --inset-y <pt>    gap below the menu bar (default 6)
          --appearance <a>  force light|dark instead of following the system
          --transparency <n> HUD transparency as 0..1, 1 being full vibrancy;
                            default "auto" follows System Settings (Accessibility
                            > Display > Reduce transparency)
          --test            show one sample HUD for the full duration, then quit
          --material <m>    vibrancy material (popover, hudWindow, menu, sidebar,
                            headerView, windowBackground, contentBackground,
                            underWindowBackground, fullScreenUI, toolTip, titlebar)
          --window          open the editor window at launch instead of waiting
                            for the menu bar item
          --snapshot <path> render the UI offscreen to a PNG and exit
          --snapshot-pane <n> which pane to render (Keys, Settings, ...)
          --board-snapshot <path>  render the HUD's spinning 3D board to a PNG
                            strip, one frame per sixth of a turn, and exit
          --studio-probe    check the ZMK Studio RPC link (USB, then Bluetooth) and exit
          --preview         show a sample HUD and quit; no Bluetooth needed
          -v, --verbose     log state transitions to stdout
          -h, --help        this text
        """)
    }
}
