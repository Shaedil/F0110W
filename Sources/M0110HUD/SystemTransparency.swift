import AppKit

/// The system's UI transparency as a level in 0...1 (1 is full vibrancy, 0 is opaque).
/// System Settings only has a switch: Accessibility > Display > Reduce transparency
/// (`reduceTransparency` = 0 or 1 in `com.apple.universalaccess`). The macOS 27 "Icon style"
/// picker only affects icons. The switch maps to the two ends, and values in between come
/// only from `--transparency`. It stays a fraction so a future system level setting would
/// work through `systemLevel()` with no other change.
final class SystemTransparency {
    /// Called on the main thread when the level changes.
    var onChange: ((Double) -> Void)?

    private(set) var level: Double = 1

    /// From `--transparency` or the debug panel. Nil follows the system.
    var override: Double? {
        didSet {
            override = override.map { min(max($0, 0), 1) }
            refresh()
        }
    }
    private let verbose: Bool

    private static let domain = "com.apple.universalaccess"

    init(override: Double?, verbose: Bool = false) {
        self.override = override.map { min(max($0, 0), 1) }
        self.verbose = verbose
        self.level = Self.resolve(override: self.override)

        // Posted when any accessibility display option changes, including Reduce transparency.
        // This lets a visible HUD restyle without being shown again.
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

    /// Re-reads the system and reports a change. Cheap enough to call on every HUD, which
    /// catches settings the system does not broadcast.
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

    /// A fractional transparency level from the accessibility domain, if the system has one.
    /// Matched by key shape, since only the switch exists today and a future key name is
    /// unknown. A key counts if it mentions transparency, holds a value strictly between 0 and
    /// 1, and does not start with "reduce" (those count the other way and would invert the HUD).
    /// 0 and 1 are left to the switch.
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
