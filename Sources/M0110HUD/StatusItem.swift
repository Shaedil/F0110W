import AppKit

/// The menu bar presence.
///
/// The app runs as a background agent with no Dock icon, so this is the only
/// thing on screen when the keyboard is behaving: the HUD is transient, and the
/// window is opened on demand rather than at launch.
///
/// It also carries "Show HUD". The connect and disconnect notifications fire on
/// events that, on a keyboard that is never slept and never disconnects, almost
/// never happen, so without a way to summon it the HUD is effectively
/// invisible.
@MainActor
final class StatusItemController {
    private let item: NSStatusItem
    private let onOpenWindow: () -> Void
    private let onShowHUD: () -> Void

    /// Current link state, shown in the menu so the icon is not the only
    /// signal.
    var connectionSummary: String = "Looking for the keyboard..." {
        didSet { stateItem.title = connectionSummary }
    }

    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    init(onOpenWindow: @escaping () -> Void, onShowHUD: @escaping () -> Void) {
        self.onOpenWindow = onOpenWindow
        self.onShowHUD = onShowHUD
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "keyboard",
                                   accessibilityDescription: "M0110")
            // A template image picks up the menu bar's own light/dark styling
            // instead of being painted once and looking wrong in one of them.
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        stateItem.isEnabled = false
        stateItem.title = connectionSummary
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open M0110...", action: #selector(openWindow), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Show HUD", action: #selector(showHUD), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit M0110", action: #selector(quit), keyEquivalent: "q")
            .target = self
        item.menu = menu
    }

    @objc private func openWindow() { onOpenWindow() }
    @objc private func showHUD() { onShowHUD() }
    @objc private func quit() { NSApp.terminate(nil) }
}

private extension NSMenu {
    /// `addItem(withTitle:action:keyEquivalent:)` returns the item on macOS,
    /// but not as a discardable result that can be configured inline.
    @discardableResult
    func addItem(withTitle title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        addItem(item)
        return item
    }
}
