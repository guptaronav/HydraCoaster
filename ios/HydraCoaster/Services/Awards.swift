import Foundation

/// Pure hydration-score, streak, and badge math (V2-T3). No SwiftData/UI
/// imports — testable without the app's runtime pieces, same reasoning as
/// GoalCalculator.
///
/// Streaks and badges always judge a day against the CURRENT base goal
/// (`AppSettings.goalML` — which already reflects whichever of manual or
/// personalized the user has selected, see `GoalPicker`/`PersonalGoalEditor`)
/// rather than the weather-scaled effective goal `TodayView`'s ring shows.
/// Weather history isn't stored anywhere, so there's no way to know what a
/// past day's effective goal actually was — re-judging old days against
/// today's weather would be meaningless anyway.
enum Awards {
    /// One calendar day's total effective ml, across ALL recorded sips —
    /// the one full-history bucketing in the app. Streaks and badges (a
    /// 30-day streak, the Century badge) need the user's whole history;
    /// History's charts window it down afterward via `Analytics.rangeTotals`.
    static func dailyTotals(from sips: [SipRecord], calendar: Calendar = .current) -> [DailyTotal] {
        var byDay: [Date: Double] = [:]
        for sip in sips {
            let day = calendar.startOfDay(for: sip.date)
            byDay[day, default: 0] += sip.effectiveGrams
        }
        return byDay.map { DailyTotal(day: $0.key, totalML: $0.value) }.sorted { $0.day < $1.day }
    }

    /// `min(100, round(consumed/goal*100))`. Zero (not a crash or NaN) when
    /// `goalML` is non-positive — a broken/unset goal reads as "no progress"
    /// rather than blowing up the Awards header.
    static func dailyScore(consumedML: Double, goalML: Double) -> Int {
        guard goalML > 0 else { return 0 }
        return min(100, Int((consumedML / goalML * 100).rounded()))
    }

    /// Consecutive goal-hit days counting backward from `today`. An
    /// incomplete today is skipped rather than counted as a miss — it
    /// doesn't break a streak that ran through yesterday, since the day
    /// isn't over yet. A complete today counts and extends the streak.
    static func currentStreak(days: [DailyTotal], goalML: Double, today: Date, calendar: Calendar = .current) -> Int {
        guard goalML > 0 else { return 0 }
        let byDay = Dictionary(uniqueKeysWithValues: days.map { (calendar.startOfDay(for: $0.day), $0.totalML) })
        func hit(_ day: Date) -> Bool { (byDay[day] ?? 0) >= goalML }

        var cursor = calendar.startOfDay(for: today)
        if !hit(cursor) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        var streak = 0
        while hit(cursor) {
            streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        return streak
    }

    /// Longest run of consecutive goal-hit days anywhere in `days`, past or
    /// present — unlike `currentStreak`, there's no "today is still in
    /// progress" carve-out here.
    static func longestStreak(days: [DailyTotal], goalML: Double, calendar: Calendar = .current) -> Int {
        guard goalML > 0 else { return 0 }
        let byDay = Dictionary(uniqueKeysWithValues: days.map { (calendar.startOfDay(for: $0.day), $0.totalML) })
        let hitDays = byDay.filter { $0.value >= goalML }.keys.sorted()

        var longest = 0
        var current = 0
        var previousHitDay: Date?
        for day in hitDays {
            if let previousHitDay, calendar.date(byAdding: .day, value: 1, to: previousHitDay) == day {
                current += 1
            } else {
                current = 1
            }
            longest = max(longest, current)
            previousHitDay = day
        }
        return longest
    }

    /// The day a run of consecutive goal-hit days first reaches `length` —
    /// the day the streak badge's criterion first became true. `nil` if no
    /// run in `hitDays` (already sorted ascending) ever reaches that length.
    private static func earnedDate(forStreakLength length: Int, hitDays: [Date], calendar: Calendar) -> Date? {
        var current = 0
        var previousHitDay: Date?
        for day in hitDays {
            if let previousHitDay, calendar.date(byAdding: .day, value: 1, to: previousHitDay) == day {
                current += 1
            } else {
                current = 1
            }
            previousHitDay = day
            if current == length {
                return day
            }
        }
        return nil
    }

    /// The day the earliest calendar week (Mon–Sun, or whatever `calendar`'s
    /// `firstWeekday` is set to) first has all 7 days hit the goal — `nil`
    /// if no week in `hitDays` ever completes.
    private static func perfectWeekEarnedDate(hitDays: [Date], calendar: Calendar) -> Date? {
        var byWeek: [DateComponents: [Date]] = [:]
        for day in hitDays {
            let key = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: day)
            byWeek[key, default: []].append(day)
        }
        let completedWeeks = byWeek.values.filter { $0.count >= 7 }
        return completedWeeks.map { $0.max()! }.min()
    }

    /// One badge id -> the date its criterion first became true. Never
    /// stored — recomputed fresh from `sips`/`days` every time.
    static func earnedBadges(
        sips: [SipRecord], days: [DailyTotal], goalML: Double, calendar: Calendar = .current
    ) -> [String: Date] {
        var earned: [String: Date] = [:]
        guard !sips.isEmpty else { return earned }

        let sortedSips = sips.sorted { $0.date < $1.date }
        earned["first-sip"] = calendar.startOfDay(for: sortedSips[0].date)

        if sortedSips.count >= 100 {
            earned["sips-100"] = calendar.startOfDay(for: sortedSips[99].date)
        }

        if let earlyBird = sortedSips.first(where: { calendar.component(.hour, from: $0.date) < 8 }) {
            earned["early-bird"] = calendar.startOfDay(for: earlyBird.date)
        }

        var cumulativeML = 0.0
        for sip in sortedSips {
            cumulativeML += sip.effectiveGrams
            if cumulativeML >= 50_000 {
                earned["liters-50"] = calendar.startOfDay(for: sip.date)
                break
            }
        }

        guard goalML > 0 else { return earned }

        let byDay = Dictionary(uniqueKeysWithValues: days.map { (calendar.startOfDay(for: $0.day), $0.totalML) })
        let hitDays = byDay.filter { $0.value >= goalML }.keys.sorted()

        if let firstGoalDay = hitDays.first {
            earned["first-goal"] = firstGoalDay
        }

        for (id, length) in [("streak-3", 3), ("streak-7", 7), ("streak-14", 14), ("streak-30", 30)] {
            if let date = earnedDate(forStreakLength: length, hitDays: hitDays, calendar: calendar) {
                earned[id] = date
            }
        }

        if let perfectWeekDate = perfectWeekEarnedDate(hitDays: hitDays, calendar: calendar) {
            earned["perfect-week"] = perfectWeekDate
        }

        return earned
    }
}

/// One entry in the Awards grid. Computed, never stored — `AppServices.
/// awardsSnapshot` pairs each id with an earned date via `Awards.
/// earnedBadges`.
struct Badge: Identifiable {
    let id: String
    let name: String
    /// SF Symbol name.
    let symbol: String
    /// Shown as the caption while the badge is still unearned.
    let detail: String
}

extension Awards {
    /// Fixed display order for the Awards grid.
    static let catalog: [Badge] = [
        Badge(id: "first-sip", name: "First Sip", symbol: "drop.fill", detail: "Log your first sip"),
        Badge(id: "first-goal", name: "Day One", symbol: "checkmark.seal.fill", detail: "Hit your goal for the first time"),
        Badge(id: "streak-3", name: "3-Day Streak", symbol: "flame", detail: "Hit your goal 3 days in a row"),
        Badge(id: "streak-7", name: "Week Streak", symbol: "flame.fill", detail: "Hit your goal 7 days in a row"),
        Badge(id: "streak-14", name: "Two-Week Streak", symbol: "flame.fill", detail: "Hit your goal 14 days in a row"),
        Badge(id: "streak-30", name: "Monthly Streak", symbol: "flame.fill", detail: "Hit your goal 30 days in a row"),
        Badge(id: "sips-100", name: "Century", symbol: "drop.circle.fill", detail: "Log 100 sips"),
        Badge(id: "liters-50", name: "Deep Reservoir", symbol: "water.waves", detail: "Drink 50 liters, lifetime"),
        Badge(id: "early-bird", name: "Early Bird", symbol: "sunrise.fill", detail: "Log a sip before 8 AM"),
        Badge(id: "perfect-week", name: "Perfect Week", symbol: "star.fill", detail: "Hit your goal every day in one week"),
    ]
}
