import AppKit
import Darwin

// stdout is block-buffered when redirected to a file or pipe, which would swallow
// --verbose output until exit. This app is long-lived and gets killed, not exited.
setvbuf(stdout, nil, _IONBF, 0)

let config = Config.resolve(CommandLine.arguments)

// A pure CLI check; no need to spin up the app or its UI.
if config.studioProbe {
    exit(StudioProbe.run(verbose: config.verbose))
}

// Offscreen renders need AppKit up but no window or event loop.
if let path = config.boardSnapshotPath {
    _ = NSApplication.shared
    exit(MainActor.assumeIsolated {
        BoardSnapshot.render(to: path, appearance: config.appearance)
    })
}


if let path = config.snapshotPath {
    _ = NSApplication.shared
    exit(MainActor.assumeIsolated {
        Snapshot.render(to: path, pane: config.snapshotPane, appearance: config.appearance)
    })
}

let app = NSApplication.shared
let delegate = AppDelegate(config: config)
app.delegate = delegate
// A menu bar agent: no Dock icon, never steals focus. `AppDelegate` promotes
// the app to .regular for as long as the editor window is open, so that window
// gets a real application menu, and drops back when it closes.
app.setActivationPolicy(.accessory)
app.run()
