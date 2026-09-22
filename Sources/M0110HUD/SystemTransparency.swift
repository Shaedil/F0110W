import AppKit

/// The system's UI transparency, expressed as a level in 0...1: 1 is full
/// vibrancy, 0 is fully opaque.
///
/// What System Settings actually publishes is a switch, not a dial. Accessibility
/// › Display › "Reduce transparency" is `accessibilityDisplayShouldReduceTransparency`,
/// a `BOOL`, and it is stored as `reduceTransparency` = 0 or 1 in
/// `com.apple.universalaccess`. On macOS 27 the Appearance pane's "Icon style:
/// Tinted / Clear" is a two-state picker over icon glass, not a window
/// transparency level. So the switch is read as the two ends of the dial, and
/// everything in between is reachable only by asking for it explicitly.
///
/// The level is still modelled as a fraction rather than a `Bool` for two
/// reasons: `--transparency` can then dial the HUD to any value, and if a
/// release does add a real level control it will land in the same defaults
/// domain and `systemLevel()` will start returning it with no other change.
final class SystemTransparency {
    /// Fires on the main thread when the resolved level changes.
    var onChange: ((Double) -> Void)?

    /// 1 = full vibrancy, 0 = fully opaque. Never read before `init` returns.
    private(set) var level: Double = 1

    /// Set from `--transparency`; `nil` follows the system.
    private let override: Double?
    private let verbose: Bool

    private static let domain = "com.apple.universalaccess"

    init(override: Double?, verbose: Bool = false) {
        self.override = override.map { min(max($0, 0), 1) }
        self.verbose = verbose
        self.level = Self.resolve(override: self.override)

        // Posted when any of the accessibility display options change, which is
        // what the "Reduce transparency" switch is. This is the live path: a
        // HUD already on screen restyles under the user without being reshown.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)

        if verbose {
            print("[transparency] level=\(String(format: "%.2f", level)) " +
                  "source=\(self.override != nil ? "--transparency" : Self.sourceName())")
        }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Re-read the system and report a change. Cheap enough to call on every
    /// HUD, which is what keeps a preference the system does not broadcast from
    /// going stale.
    @discardableResult
    func refresh() -> Double {
        let next = Self.resolve(override: override)
        guard abs(next - level) > 0.001 else { return level }
        level = next
        if verbose { print("[transparency] level -> \(String(format: "%.2f", next))") }
        onChange?(next)
        return next
    }

    @objc private func systemChanged() { refresh() }

    private static func resolve(override: Double?) -> Double {
        if let override { return override }
        if let published = systemLevel() { return published }
        return NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 0 : 1
    }

    private static func sourceName() -> String {
        systemLevel() != nil ? "\(domain) level key" : "reduceTransparency switch"
    }

    /// A fractional transparency level from the accessibility domain, if the
    /// running system publishes one.
    ///
    /// Read by shape rather than by a hardcoded name, because the only key that
    /// exists today is the switch and a future dial would arrive under a name
    /// that cannot be known ahead of time. A key qualifies when it mentions
    /// transparency, holds a fraction strictly between 0 and 1, and is not a
    /// "reduce"-style key — a key named for reduction counts the other way, and
    /// reading it as a transparency level would invert the HUD. A whole 0 or 1
    /// is left to the switch below, which already means the same thing.
    private static func systemLevel() -> Double? {
        guard let keys = CFPreferencesCopyKeyList(domain as CFString,
                                                  kCFPreferencesCurrentUser,
                                                  kCFPreferencesAnyHost) as? [String]
        else { return nil }

        for key in keys {
            let name = key.lowercased()
            guard name.contains("transparen"), !name.hasPrefix("reduce") else { continue }
            guard let value = CFPreferencesCopyValue(key as CFString,
                                                     domain as CFString,
                                                     kCFPreferencesCurrentUser,
                                                     kCFPreferencesAnyHost) as? NSNumber
            else { continue }
            let fraction = value.doubleValue
            guard fraction > 0, fraction < 1 else { continue }
            return fraction
        }
        return nil
    }
}
