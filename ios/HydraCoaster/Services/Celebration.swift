import Foundation

/// Pure decision logic for V2-T7's coaster celebration (D007 0x05): fires
/// once per calendar day, the first time today's consumption crosses the
/// goal. No SwiftData/BLE imports — testable without the app's runtime
/// pieces, same reasoning as GoalCalculator/Awards.
enum Celebration {
    /// True iff `goalML` is positive, `consumedML` has reached it, and
    /// `lastCelebrated` is either unset or falls on a different calendar day
    /// than `now` — i.e. "first crossing today". Callers pass whatever goal
    /// the Today ring is currently showing (weather-scaled), so a user never
    /// sees a full ring with no celebration.
    static func shouldCelebrate(
        consumedML: Double,
        goalML: Double,
        lastCelebrated: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard goalML > 0, consumedML >= goalML else { return false }
        guard let lastCelebrated else { return true }
        return !calendar.isDate(lastCelebrated, inSameDayAs: now)
    }
}
