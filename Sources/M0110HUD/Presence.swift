import Foundation

/// Decides when the keyboard has really left, as opposed to dropping its link
/// for a moment and coming straight back.
///
/// Two signals feed it. A poll of what the system has connected, every couple
/// of seconds, and this app's own GATT link to the keyboard, which reports a
/// drop the instant it happens. The poll alone missed most drops: one shorter
/// than the poll interval usually fell between two polls and was never seen,
/// so whether a disconnect was announced came down to luck.
///
/// Instead, either signal only opens a grace period. When it ends the keyboard
/// is checked again: gone means it left, and is announced; back means it was a
/// blip, and nothing is said either way. Blips are common (the link drops and
/// re-forms in well under a second several times a day) and announcing each as
/// a disconnect and a connect would be noise.
struct Presence {
    enum Change: Equatable {
        /// The keyboard is here and was not. Announce a connect.
        case arrived
        /// The keyboard is gone and stayed gone past the grace period.
        /// Announce a disconnect.
        case left
        /// It may be leaving. Check again at this time.
        case leaving(until: Date)
        /// It was missing, but was back by the end of the grace period.
        case stayed(missingFor: TimeInterval)
    }

    /// How long the keyboard must stay gone to count as having left. Zero
    /// announces every drop the moment it is seen.
    let grace: TimeInterval

    /// Whether the keyboard is here, as last announced. Stays true through a
    /// grace period.
    private(set) var isPresent = false
    /// When it was last seen to go missing, while a grace period runs.
    private(set) var missingSince: Date?

    init(grace: TimeInterval) {
        self.grace = max(0, grace)
    }

    /// A poll result: is the keyboard among the system's connected devices?
    mutating func observe(present: Bool, at now: Date) -> Change? {
        if let since = missingSince {
            // Polls inside the grace period say nothing: the link may still be
            // re-forming, or not yet torn down. Only the check at its end counts.
            guard now >= since.addingTimeInterval(grace) else { return nil }
            missingSince = nil
            if present { return .stayed(missingFor: now.timeIntervalSince(since)) }
            isPresent = false
            return .left
        }

        switch (isPresent, present) {
        case (false, true):
            isPresent = true
            return .arrived
        case (true, false):
            return beginMissing(at: now)
        default:
            return nil
        }
    }

    /// This app's own link to the keyboard dropped. That happens when the
    /// keyboard goes, but also on its own, so it only opens a grace period.
    mutating func linkDropped(at now: Date) -> Change? {
        guard isPresent, missingSince == nil else { return nil }
        return beginMissing(at: now)
    }

    private mutating func beginMissing(at now: Date) -> Change {
        missingSince = now
        return .leaving(until: now.addingTimeInterval(grace))
    }
}
