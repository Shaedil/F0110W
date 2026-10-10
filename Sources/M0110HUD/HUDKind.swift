import Foundation

/// What a HUD is announcing.
enum HUDKind: String, CaseIterable {
    /// The first connect of the day: after hours away, or on a new day.
    case arrived
    /// Any other connect.
    case connected
    case lowBattery
    case disconnected
    /// Battery ran out: a 0% report, or a disconnect right after a near-empty reading.
    case died
    /// The keyboard switched to another profile.
    case movedAway
    /// The keyboard switched back to this computer.
    case movedBack

    var showsRing: Bool {
        switch self {
        case .arrived, .connected, .lowBattery, .movedBack: true
        case .disconnected, .died, .movedAway: false
        }
    }

    /// The line under the keyboard's name. `detail` is the profile name on a moved-away HUD.
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

/// This computer's copy of the names the keyboard stores (see `ProfileNameStore`).
enum ProfileNames {
    static let count = 5

    static func key(_ index: Int) -> String { "profileName\(index)" }

    /// Name for a 0-based profile index, or "Profile N" if unset.
    static func name(for index: Int, in defaults: UserDefaults = .standard) -> String {
        if let n = defaults.string(forKey: key(index))?.trimmingCharacters(in: .whitespaces),
           !n.isEmpty {
            return n
        }
        return placeholder(index)
    }

    static func placeholder(_ index: Int) -> String { "Profile \(index + 1)" }
}
