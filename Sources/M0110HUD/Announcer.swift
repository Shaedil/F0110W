import Foundation

struct Announcement: Equatable {
    var kind: HUDKind
    var battery: Int?
    /// The profile name on a moved-away HUD.
    var detail: String? = nil
}

/// What the announcer remembers across launches.
protocol AnnouncerMemory: AnyObject {
    /// Saved so a relaunch on a low battery does not alert again.
    var lowAlertArmed: Bool { get set }
    /// Saved so a relaunch does not announce the same level again.
    var lastMilestone: Int? { get set }
    /// Saved because the gap before the day's first connect is usually a night,
    /// and the app may restart during it.
    var lastConnectAt: Date? { get set }
    var lastDisconnectAt: Date? { get set }
    /// Kept here because the monitor clears it on disconnect, which is exactly
    /// when it is needed to tell "disconnected" from "died".
    var lastBattery: Int? { get set }
    /// Stays set until the battery charges again, so a level bouncing on 0 shows the HUD once.
    var diedAnnounced: Bool { get set }
}

/// Decides which HUD, if any, each keyboard report should show. Shared by the Mac and Windows apps.
final class Announcer {
    var config: Config
    unowned let memory: AnnouncerMemory
    var profileName: (Int) -> String = { ProfileNames.name(for: $0) }

    /// Not saved, since the keyboard reports both profiles on every connect and a
    /// stale value would show a move that never happened.
    private(set) var activeProfile: Int?
    private(set) var ownProfile: Int?
    private(set) var lastMove: ProfileMove?

    /// A connect this long after the last disconnect also counts as the first of the day.
    static let arrivalGap: TimeInterval = 4 * 3600
    /// A disconnect at or below this level means the battery died.
    static let diedLevel = 2

    init(config: Config, memory: AnnouncerMemory) {
        self.config = config
        self.memory = memory
    }

    /// `battery` is nil until this connect's reading arrives. Old levels are not used since they may be stale.
    func connect(battery: Int?, isInitial: Bool, now: Date = Date()) -> Announcement? {
        let arrival = isArrival(at: now)
        memory.lastConnectAt = now
        if isInitial && config.suppressInitial { return nil }
        return Announcement(kind: arrival ? .arrived : .connected, battery: battery)
    }

    /// True for the first connect ever, on a new calendar day, or after `arrivalGap` away.
    func isArrival(at now: Date) -> Bool {
        guard let last = memory.lastConnectAt else { return true }
        if !Calendar.current.isDate(last, inSameDayAs: now) { return true }
        guard let left = memory.lastDisconnectAt, left >= last else { return false }
        return now.timeIntervalSince(left) >= Self.arrivalGap
    }

    func disconnect(now: Date = Date()) -> Announcement? {
        memory.lastDisconnectAt = now
        activeProfile = nil
        if let level = memory.lastBattery, level <= Self.diedLevel {
            // Shown even when disconnect HUDs are off, unless a 0% report already showed it.
            guard !memory.diedAnnounced else { return nil }
            memory.diedAnnounced = true
            return Announcement(kind: .died, battery: level)
        }
        guard config.showDisconnect else { return nil }
        return Announcement(kind: .disconnected, battery: nil)
    }

    /// `active` is the profile the keyboard now types to and `own` is this computer's, both
    /// 0-based (`own` is nil if not reported). Only moves to or from this computer show a HUD.
    func profileSwitch(active: Int, own: Int?) -> Announcement? {
        if let own { ownProfile = own }
        let move = ProfileMove(previous: activeProfile, active: active, own: ownProfile)
        activeProfile = active
        lastMove = move

        switch move.outcome {
        case .away:
            return Announcement(kind: .movedAway, battery: memory.lastBattery,
                                detail: profileName(active))
        case .back:
            return Announcement(kind: .movedBack, battery: memory.lastBattery)
        case .firstReport, .unchanged, .ownUnknown, .elsewhere:
            return nil
        }
    }

    /// Returns the HUDs to show in order, each replacing the one before.
    func battery(level: Int) -> [Announcement] {
        memory.lastBattery = level

        if level <= 0, !memory.diedAnnounced {
            memory.diedAnnounced = true
            return [Announcement(kind: .died, battery: level)]
        } else if level > Self.diedLevel + 3 {
            memory.diedAnnounced = false
        }

        var shown: [Announcement] = []
        if memory.lowAlertArmed, level <= config.lowThreshold {
            memory.lowAlertArmed = false
            shown.append(Announcement(kind: .lowBattery, battery: level))
        } else if !memory.lowAlertArmed, level >= config.rearmThreshold {
            memory.lowAlertArmed = true
        }

        if let milestone = milestone(level: level) { shown.append(milestone) }
        return shown
    }

    /// Shows a HUD each time the level drops through a milestone, since the low alert rarely
    /// fires on a 10 Ah cell. The percentage is a linear voltage curve (about 7.5 mV per point)
    /// that moves with load, so only drops announce, and a milestone rearms only after the
    /// level climbs a full step above it.
    private func milestone(level: Int) -> Announcement? {
        let step = config.batteryMilestone
        guard step > 0 else { return nil }

        let crossed = (level / step) * step
        guard crossed > 0, crossed < 100 else { return nil }

        if let last = memory.lastMilestone {
            guard crossed < last else {
                // Rising. Rearm only once clear of the boundary so jitter does not toggle it.
                if crossed > last + step { memory.lastMilestone = crossed }
                return nil
            }
        }
        memory.lastMilestone = crossed
        return Announcement(kind: level <= config.lowThreshold ? .lowBattery : .connected,
                            battery: level)
    }

    func resetHistory() {
        memory.lastConnectAt = nil
        memory.lastDisconnectAt = nil
        memory.lastBattery = nil
        memory.diedAnnounced = false
        activeProfile = nil
        ownProfile = nil
        lastMove = nil
    }
}

/// The keyboard's active profile vs this computer's, both 0-based. ZMK keeps every
/// profile's link up, so the keyboard looks connected here even while typing elsewhere.
struct ProfileState: Equatable {
    var active: Int
    /// Nil until the keyboard reports which profile is this computer.
    var own: Int?

    var typingHere: Bool? { own.map { $0 == active } }

    #if os(Windows)
    static let thisComputer = "this PC"
    #else
    static let thisComputer = "this Mac"
    #endif

    func activeName(in defaults: UserDefaults = .standard) -> String {
        ProfileNames.name(for: active, in: defaults)
    }

    /// Hover text. Adds the profile number unless the name is already "Profile N".
    func summary(in defaults: UserDefaults = .standard) -> String? {
        guard let here = typingHere else { return nil }
        let name = activeName(in: defaults)
        let number = "Profile \(active + 1)"
        if here {
            return "Typing to \(Self.thisComputer) (\(name))"
        }
        return name == number ? "Typing to \(name)" : "Typing to \(name) (\(number))"
    }
}

/// What one profile report means for this computer. Always logged, so a switch
/// that showed nothing says why.
struct ProfileMove: Equatable {
    enum Outcome: Equatable {
        case firstReport
        /// ZMK also reports when the active computer connects or drops.
        case unchanged
        case ownUnknown
        case away
        case back
        /// Between two other computers.
        case elsewhere
    }

    /// All 0-based.
    var previous: Int?
    var active: Int
    var own: Int?

    var outcome: Outcome {
        guard let previous else { return .firstReport }
        guard previous != active else { return .unchanged }
        guard let own else { return .ownUnknown }
        if previous == own { return .away }
        if active == own { return .back }
        return .elsewhere
    }

    /// Log line. Profiles are numbered from 1 to match Settings.
    var explanation: String {
        let to = "Profile \(active + 1)"
        let mine = own.map { "Profile \($0 + 1)" } ?? "unknown"
        let move = previous.map { "Profile \($0 + 1) to \(to)" } ?? to
        switch outcome {
        case .firstReport:
            return "\(to) active, this computer is \(mine); first report since connecting, nothing shown"
        case .unchanged:
            return "\(to) still active, this computer is \(mine); nothing shown"
        case .ownUnknown:
            return "\(move), but the keyboard did not say which profile is this computer; nothing shown"
        case .away:
            return "\(move), away from this computer (\(mine)); showing \"Moved to\""
        case .back:
            return "\(move), back to this computer; showing \"Moved back\""
        case .elsewhere:
            return "\(move), neither is this computer (\(mine)); nothing shown"
        }
    }
}
