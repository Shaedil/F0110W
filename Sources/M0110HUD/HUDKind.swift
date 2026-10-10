import Foundation

/// What a HUD is announcing.
enum HUDKind: String, CaseIterable {
    /// The first connect of the day: after hours away, or on a new day.
    case arrived
    /// Any other connect.
    case connected
    case lowBattery
    case disconnected
    /// Gone with a flat battery: a report of 0%, or a disconnect right after
    /// a near-empty one.
    case died
    /// The keyboard switched to another of its Bluetooth profiles.
    case movedAway
    /// The keyboard switched back to this computer from another profile.
    case movedBack

    /// Whether the battery ring belongs on this HUD when a level is known.
    var showsRing: Bool {
        switch self {
        case .arrived, .connected, .lowBattery, .movedBack: true
        case .disconnected, .died, .movedAway: false
        }
    }

    /// The line under the keyboard's name. `detail` is the profile name on a
    /// moved-away HUD.
    func status(detail: String? = nil) -> String {
        switch self {
        case .arrived, .connected: "Connected"
        case .disconnected:        "Disconnected"
        case .lowBattery:          "Low Battery"
        case .died:                "Battery Empty"
        case .movedAway:           "Moved to \(detail ?? "another device")"
        case .movedBack:           "Moved back"
        }
    }
}

/// Profile names, for "Moved to ...": this computer's copy of the ones the
/// keyboard keeps (see `ProfileNameStore`).
enum ProfileNames {
    static let count = 5

    static func key(_ index: Int) -> String { "profileName\(index)" }

    /// The name for a 0-based profile index, or "Profile N" when none is set.
    static func name(for index: Int, in defaults: UserDefaults = .standard) -> String {
        if let n = defaults.string(forKey: key(index))?.trimmingCharacters(in: .whitespaces),
           !n.isEmpty {
            return n
        }
        return placeholder(index)
    }

    /// What a profile with no name is called.
    static func placeholder(_ index: Int) -> String { "Profile \(index + 1)" }
}
