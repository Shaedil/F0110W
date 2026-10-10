import AppKit
import Darwin

// stdout is block-buffered when redirected, and the app is usually killed, so
// --verbose output would be lost.
setvbuf(stdout, nil, _IONBF, 0)

let config = Config.resolve(CommandLine.arguments)

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
if let path = config.stageSnapshotPath {
    _ = NSApplication.shared
    exit(MainActor.assumeIsolated { BoardStageSnapshot.render(to: path) })
}


if let path = config.snapshotPath {
    _ = NSApplication.shared
    exit(MainActor.assumeIsolated {
        Snapshot.render(to: path, pane: config.snapshotPane, appearance: config.appearance,
                        time: config.snapshotTime)
    })
}

let app = NSApplication.shared
let delegate = AppDelegate(config: config)
app.delegate = delegate
// Menu bar agent with no Dock icon. `AppDelegate` switches to .regular while the
// window is open so it gets an app menu.
app.setActivationPolicy(.accessory)
app.run()
