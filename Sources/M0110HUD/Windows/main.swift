import CM0110Win
import Foundation

// build.ps1 marks the release executable a GUI program, so starting it at
// login opens no console. Asked for output from a terminal, it borrows that
// terminal's.
m0110_attach_console()

func printUsage() {
    print("""
    M0110HUD: connect, disconnect and battery HUD for a Bluetooth keyboard.

      --name <str>      paired Bluetooth device to watch (default: M0110)
      --low <pct>       low-battery trigger, once per descent (default: 20)
      --rearm <pct>     level the battery must return to before re-alerting (default: 30)
      --milestone <pct> announce each drop through a multiple of this (default: 10;
                        0 disables, leaving only the low-battery alert)
      --duration <sec>  how long the HUD stays visible (default: 7)
      --no-disconnect   don't show a HUD when the keyboard disconnects
      --disconnect-grace <sec>  how long the keyboard must stay gone before a
                        disconnect is announced (default: 3; 0 announces every drop)
      --no-initial      stay quiet if the keyboard is already connected at launch
      --scale <factor>  resize the whole HUD (default 1.0)
      --appearance <a>  force light|dark instead of following the taskbar
      --test            show one sample HUD for the full duration, then quit
      --preview         show each HUD state in turn, then quit
      --snapshot <path> draw every HUD state and the tray icon to a .bmp, then quit
      --studio-probe    check the ZMK Studio RPC link over USB and exit
      --ble-probe       show what Windows reports for the keyboard and exit
      --clipboard-probe try the clipboard and image handling on this PC and exit
                        (replaces what is on the clipboard)
      --window          open the M0110 window at launch
      --install         start at login, with the other options given here
      --uninstall       stop starting at login
      -v, --verbose     log state transitions

    Profile names for "Moved to ..." are kept on the keyboard and set in the
    window's Bluetooth pane; %LOCALAPPDATA%\\M0110HUD\\settings.json keeps a copy.
    """)
}

// The options only Windows has, taken out before the shared Config sees the
// rest. Its own --help describes the Mac app, so that is answered here.
var arguments = CommandLine.arguments
var bleProbe = false
var clipboardProbe = false
var install: Bool?
for option in arguments.dropFirst() {
    switch option {
    case "-h", "--help": printUsage(); exit(0)
    case "--ble-probe": bleProbe = true
    case "--clipboard-probe": clipboardProbe = true
    case "--install": install = true
    case "--uninstall": install = false
    default: continue
    }
}
arguments.removeAll { ["--ble-probe", "--clipboard-probe", "--install", "--uninstall"].contains($0) }

// The window's settings, under any flags given here.
UserDefaults.standard.register(defaults: WinSettings.load().defaults)
let config = Config.resolve(arguments)

if config.studioProbe {
    exit(StudioProbe.run(verbose: config.verbose))
}
if bleProbe {
    exit(BLEProbe.run(name: config.deviceName))
}
if clipboardProbe {
    exit(ClipboardProbe.run())
}
if let install {
    // Everything but the install flag itself goes with it into the Run key.
    let status = WinApp.setRunAtLogin(install, arguments: Array(arguments.dropFirst()))
    print(status == 0 ? (install ? "M0110HUD will start at login." : "M0110HUD will not start at login.")
                      : "could not change the Run key: error \(status)")
    exit(status == 0 ? 0 : 1)
}
if let path = config.snapshotPath {
    let sheet = HUDArt.sheet(scale: Float(m0110_current_screen().dpi) / 96 * Float(config.scale), text: GDIText())
    do {
        try Data(sheet.bmp()).write(to: URL(fileURLWithPath: path))
        print(path)
        exit(0)
    } catch {
        FileHandle.standardError.write("could not write \(path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

exit(WinApp(config: config).run())
