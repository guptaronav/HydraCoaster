import Foundation

/// One day's total intake. A named struct rather than the tuple this was
/// specced as — arrays of tuples aren't Equatable, and tests need `==`.
struct DailyTotal: Equatable, Sendable {
    let day: Date
    let totalML: Double
}

enum DailyTotals {
    static let windowDays = 14

    /// Buckets sips into calendar-day totals for the trailing `windowDays`
    /// days (today inclusive, oldest first), zero-filling days with no
    /// sips. `now`/`calendar` are injectable so tests don't depend on the
    /// real clock.
    static func compute(
        from records: [SipRecord],
        endingAt now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyTotal] {
        let today = calendar.startOfDay(for: now)
        let days = (0..<windowDays)
            .compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
            .reversed()

        var totalsByDay: [Date: Double] = [:]
        for record in records {
            let day = calendar.startOfDay(for: record.date)
            totalsByDay[day, default: 0] += record.grams
        }

        return days.map { day in
            DailyTotal(day: day, totalML: totalsByDay[day] ?? 0)
        }
    }
}
