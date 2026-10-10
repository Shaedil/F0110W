import AppKit
import SwiftUI

/// What the menu header shows. Updated by the app delegate on the main thread.
final class StatusModel: ObservableObject {
    /// Shared by the menu and the window.
    static let shared = StatusModel()
    @Published var name = "M0110"
    /// The Bluetooth link the HUD watches.
    @Published var linked = false
    @Published var battery: Int?
    /// Nil until the first profile report, after a disconnect, and on older firmware.
    @Published var profile: ProfileState?
    /// The Studio link the window uses to edit the keymap.
    @Published var editor: KeyboardController.Connection = .disconnected
}

/// The menu bar item. The app has no Dock icon, so this is its only permanent UI.
/// "Show HUD" is here because connects and disconnects are rare on a keyboard that never
/// sleeps, so the HUD would almost never appear otherwise.
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
            // A template image follows the menu bar's light/dark styling.
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

/// Laid out like Control Center accessory rows. The last line shows whether the keymap can
/// be edited, since that uses a separate link.
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
    /// Redeclared as `@discardableResult` so the returned item can be configured inline.
    @discardableResult
    func addItem(withTitle title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        addItem(item)
        return item
    }
}
