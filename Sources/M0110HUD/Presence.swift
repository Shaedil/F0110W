import Foundation

/// Decides when the keyboard has really left, instead of briefly dropping its link.
/// The system poll (every couple of seconds) misses drops shorter than the poll interval, so
/// this app's GATT link, which reports a drop at once, feeds it too. Either signal only starts
/// a grace period. At its end the keyboard is checked again: still gone means it left, and
/// back means it was a short drop that is not announced.
struct Presence {
    enum Change: Equatable {
        /// Newly present. Announce a connect.
        case arrived
        /// Gone past the grace period. Announce a disconnect.
        case left
        /// It may be leaving. Check again at this time.
        case leaving(until: Date)
        /// Missing, but back by the end of the grace period.
        case stayed(missingFor: TimeInterval)
    }

    /// 0 announces every drop as soon as it is seen.
    let grace: TimeInterval

    /// As last announced. Stays true during a grace period.
    private(set) var isPresent = false
    /// Set while a grace period runs.
    private(set) var missingSince: Date?

    init(grace: TimeInterval) {
        self.grace = max(0, grace)
    }

    /// A poll result: whether the keyboard is among the system's connected devices.
    mutating func observe(present: Bool, at now: Date) -> Change? {
        if let since = missingSince {
            // Ignore polls during the grace period, since the link may still be reconnecting or
            // closing. Only the check at the end counts.
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

    /// The GATT link also drops by itself, so this only starts a grace period.
    mutating func linkDropped(at now: Date) -> Change? {
        guard isPresent, missingSince == nil else { return nil }
        return beginMissing(at: now)
    }

    private mutating func beginMissing(at now: Date) -> Change {
        missingSince = now
        return .leaving(until: now.addingTimeInterval(grace))
    }
}
