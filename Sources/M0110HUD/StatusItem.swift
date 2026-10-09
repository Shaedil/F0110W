import AppKit
import SwiftUI

/// What the menu's header shows. The app delegate keeps it current from the
/// Bluetooth monitor and the Studio link, always on the main thread.
final class StatusModel: ObservableObject {
    /// The one the menu shows, which the window reads too.
    static let shared = StatusModel()
    @Published var name = "M0110"
    /// The Bluetooth link the HUD watches: is the keyboard typing to this Mac.
    @Published var linked = false
    @Published var battery: Int?
    /// Which profile the keyboard types to, from its profile report. Nil
    /// until the first report and after a disconnect, and always on firmware
    /// that predates the report.
    @Published var profile: ProfileState?
    /// The Studio link the window edits the keymap over.
    @Published var editor: KeyboardController.Connection = .disconnected
}

/// The keyboard's active Bluetooth profile against the one that is this
/// computer, both 0-based. ZMK keeps every profile's link up, so the keyboard
/// reads as connected here even while it types to another computer; this is
/// what tells the two apart.
struct ProfileState: Equatable {
    var active: Int
    /// Nil when the keyboard has not said which profile is this computer.
    var own: Int?

    /// Nil when that cannot be told, for want of `own`.
    var typingHere: Bool? { own.map { $0 == active } }

    /// The active profile's name, as the user gave it in Settings.
    func activeName(in defaults: UserDefaults = .standard) -> String {
        ProfileNames.name(for: active, in: defaults)
    }

    /// One line for a hover: where the keystrokes are going. The profile's
    /// number is added only when its name is not already "Profile N".
    func summary(in defaults: UserDefaults = .standard) -> String? {
        guard let here = typingHere else { return nil }
        let name = activeName(in: defaults)
        let number = "Profile \(active + 1)"
        if here {
            return "Typing to this Mac (\(name))"
        }
        return name == number ? "Typing to \(name)" : "Typing to \(name) (\(number))"
    }
}

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
    nonisolated let model = StatusModel.shared
    private let item: NSStatusItem
    private let onOpenWindow: () -> Void
    private let onShowHUD: () -> Void

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
        let header = NSMenuItem()
        let host = NSHostingView(rootView: StatusHeader(model: model))
        host.frame.size = NSSize(width: StatusHeader.width, height: host.fittingSize.height)
        // Let the header grow when its second line comes and goes.
        host.sizingOptions = [.intrinsicContentSize]
        header.view = host
        menu.addItem(header)
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

/// The top of the menu, laid out like the accessory rows in Control Center:
/// a glyph in a disc, the name, and one line of state beneath it, with the
/// battery on the right. A second, quieter line says whether the keymap can
/// be edited, since that link is separate from the one that types.
private struct StatusHeader: View {
    static let width: CGFloat = 280
    @ObservedObject var model: StatusModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "keyboard")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.linked ? Color.white : Color.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(model.linked ? Color.accentColor : Color.secondary.opacity(0.18)))

            VStack(alignment: .leading, spacing: 1) {
                Text(model.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(linkLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(editorLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            if model.linked, let battery = model.battery {
                HStack(spacing: 4) {
                    Text("\(battery)%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: Self.batterySymbol(battery))
                        .font(.system(size: 14))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(battery <= 20 ? Color.red : Color.primary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: Self.width, alignment: .leading)
    }

    private var linkLine: String {
        guard model.linked else { return "Not connected" }
        guard let profile = model.profile, let here = profile.typingHere else { return "Connected" }
        return here ? "Connected \u{00B7} typing here" : "Connected \u{00B7} on \(profile.activeName())"
    }

    private var editorLine: String {
        switch model.editor {
        case .connected(let port, _):
            return port.hasPrefix("/dev/") ? "Keymap editing over USB" : "Keymap editing over Bluetooth"
        case .connecting: return "Looking for the keymap editor..."
        case .disconnected, .failed: return "Keymap editing unavailable"
        }
    }

    private static func batterySymbol(_ level: Int) -> String {
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
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
