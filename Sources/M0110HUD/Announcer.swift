import Foundation

/// One HUD to put on screen.
struct Announcement: Equatable {
    var kind: HUDKind
    var battery: Int?
    /// The profile name on a moved-away HUD.
    var detail: String? = nil
}

/// What the announcer remembers across launches.
protocol AnnouncerMemory: AnyObject {
    /// Persisted so a relaunch on an already-low battery doesn't re-nag.
    var lowAlertArmed: Bool { get set }
    /// The last milestone announced, persisted for the same reason: a relaunch
    /// should not re-announce a level the user has already been told about.
    var lastMilestone: Int? { get set }
    /// When the keyboard last connected and last left, for telling the first
    /// connect of the day from the rest. Persisted: the gap that makes an
    /// arrival is usually a night, and the app may well restart inside it.
    var lastConnectAt: Date? { get set }
    var lastDisconnectAt: Date? { get set }
    /// The last level the keyboard reported. The monitor forgets it on
    /// disconnect, but that is exactly when the announcer decides between
    /// "disconnected" and "died".
    var lastBattery: Int? { get set }
    /// Set once the empty-battery HUD has been shown, until the battery is
    /// charged again, so a level bouncing on 0 does not repeat it.
    var diedAnnounced: Bool { get set }
}

/// Decides which HUD, if any, each thing the keyboard reports should show.
///
/// Shared by the Mac and Windows apps, so both say the same things at the
/// same moments; each platform only decides how a HUD looks.
final class Announcer {
    var config: Config
    unowned let memory: AnnouncerMemory
    /// The name for a 0-based profile index, for "Moved to ...".
    var profileName: (Int) -> String = { ProfileNames.name(for: $0) }

    /// The keyboard's active profile as last reported, and which profile is
    /// this computer. Not persisted: the keyboard reports both afresh on every
    /// connect, and a stale value would announce a move that never happened.
    private(set) var activeProfile: Int?
    private(set) var ownProfile: Int?
    /// What the last profile report meant, for the log.
    private(set) var lastMove: ProfileMove?

    /// Hours apart that make a connect the first of a new day, on top of any
    /// connect on a new calendar day.
    static let arrivalGap: TimeInterval = 4 * 3600
    /// A disconnect at or below this level is the battery dying, not leaving.
    static let diedLevel = 2

    init(config: Config, memory: AnnouncerMemory) {
        self.config = config
        self.memory = memory
    }

    /// `battery` is the level read on this connect, or nil if the read has not
    /// landed yet. The last session's level is deliberately not shown in its
    /// place: it was wrong whenever the keyboard had charged or drained while
    /// away. A late read fills the ring in through `battery(level:)`.
    func connect(battery: Int?, isInitial: Bool, now: Date = Date()) -> Announcement? {
        let arrival = isArrival(at: now)
        memory.lastConnectAt = now
        if isInitial && config.suppressInitial { return nil }
        return Announcement(kind: arrival ? .arrived : .connected, battery: battery)
    }

    /// The first connect of the day: none before, a new calendar day since the
    /// last, or long enough away that it is a new stretch of work.
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
            // Leaving on an empty battery is dying, whatever else is set: it
            // is the one disconnect worth knowing about. Unless a report of 0%
            // already said so a moment ago.
            guard !memory.diedAnnounced else { return nil }
            memory.diedAnnounced = true
            return Announcement(kind: .died, battery: level)
        }
        guard config.showDisconnect else { return nil }
        return Announcement(kind: .disconnected, battery: nil)
    }

    /// The keyboard switched Bluetooth profile. `active` is the profile it now
    /// types to, `own` the one that is this computer, both 0-based; `own` is
    /// nil when the keyboard did not say.
    ///
    /// Only the moves that involve this computer say anything: away from it,
    /// or back to it. The first report after a connect only sets the scene.
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

    /// A fresh battery reading. Returns the HUDs it calls for in order, each
    /// replacing the one before it on screen.
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

    /// Show a HUD each time the level drops through a milestone.
    ///
    /// The low-battery alert fires once per descent, which on a 10 Ah cell is
    /// roughly never, so it was the only battery notification and it almost
    /// never appeared. Milestones give the ordinary discharge something to say.
    ///
    /// The reported percentage is not state of charge: it is a linear voltage
    /// curve at ~7.5 mV per point, so load alone moves it several points either
    /// way. Hence the guards:
    ///
    ///   * descending only: a level climbing back through a milestone rearms
    ///     it without announcing it
    ///   * a rearm margin: the level must recover well past a milestone before
    ///     that milestone can fire again, so jitter around the boundary cannot
    ///     produce a burst
    private func milestone(level: Int) -> Announcement? {
        let step = config.batteryMilestone
        guard step > 0 else { return nil }

        // The highest milestone at or below the current level.
        let crossed = (level / step) * step
        guard crossed > 0, crossed < 100 else { return nil }

        if let last = memory.lastMilestone {
            guard crossed < last else {
                // Recovering. Only rearm once it is clear of the boundary, so a
                // level hovering on it does not toggle.
                if crossed > last + step { memory.lastMilestone = crossed }
                return nil
            }
        }
        memory.lastMilestone = crossed
        return Announcement(kind: level <= config.lowThreshold ? .lowBattery : .connected,
                            battery: level)
    }

    /// Forget the day and battery history.
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

    #if os(Windows)
    static let thisComputer = "this PC"
    #else
    static let thisComputer = "this Mac"
    #endif

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
            return "Typing to \(Self.thisComputer) (\(name))"
        }
        return name == number ? "Typing to \(name)" : "Typing to \(name) (\(number))"
    }
}

/// What one profile report means for this computer, against the profile
/// that was active before it. Logged whichever way it goes, so a switch that
/// showed nothing says why.
struct ProfileMove: Equatable {
    enum Outcome: Equatable {
        /// The first report since connecting: nothing to compare with.
        case firstReport
        /// ZMK also reports when the active computer connects or drops.
        case unchanged
        /// The keyboard has not said which profile is this computer.
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

    /// One line for the log, numbered from 1 as Settings names the profiles.
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
