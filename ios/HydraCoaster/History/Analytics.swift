import Foundation

/// Pure logic for the History tab's V2-T5 analytics: range charts, the
/// per-drink breakdown, the calendar heatmap, and CSV export. No SwiftData/
/// UI imports, same reasoning as `Awards`/`DailyTotals` — testable with
/// plain `SipRecord`/`DailyTotal` arrays and fixed dates.
enum Analytics {
    /// Buckets sips into calendar-day totals for the trailing `range.days`
    /// days ending on `endingOn` (inclusive), zero-filling days with no
    /// sips so charts get a continuous axis. `days` should be the FULL,
    /// unwindowed history (`Awards.dailyTotals`) — this trims/zero-fills a
    /// window out of it, mirroring `DailyTotals.compute`'s own idiom but
    /// parameterized over week/month instead of a fixed 14 days.
    static func rangeTotals(
        days: [DailyTotal], range: HistoryRange, endingOn: Date, calendar: Calendar
    ) -> [DailyTotal] {
        let totalsByDay = Dictionary(uniqueKeysWithValues: days.map { (calendar.startOfDay(for: $0.day), $0.totalML) })
        let today = calendar.startOfDay(for: endingOn)
        let windowDays = (0..<range.days)
            .compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
            .reversed()
        return windowDays.map { day in DailyTotal(day: day, totalML: totalsByDay[day] ?? 0) }
    }

    /// Sums each sip's raw/effective ml into its drink's category over the
    /// trailing `range.days` days ending on `endingOn` (inclusive), sorted
    /// by effective ml descending. Category is resolved via
    /// `DrinkCatalog.drink(for:)`, which already falls back to water for an
    /// unrecognized id — `SipRecord.typeID` defaults to water's id too, so
    /// there's no separate nil case to special-case here.
    static func typeBreakdown(
        sips: [SipRecord], range: HistoryRange, endingOn: Date, calendar: Calendar
    ) -> [TypeSlice] {
        let today = calendar.startOfDay(for: endingOn)
        guard let windowStart = calendar.date(byAdding: .day, value: -(range.days - 1), to: today) else { return [] }

        var effectiveByCategory: [String: Double] = [:]
        var rawByCategory: [String: Double] = [:]
        for sip in sips {
            let day = calendar.startOfDay(for: sip.date)
            guard day >= windowStart, day <= today else { continue }
            let category = DrinkCatalog.drink(for: sip.typeID).category.rawValue
            effectiveByCategory[category, default: 0] += sip.effectiveGrams
            rawByCategory[category, default: 0] += sip.grams
        }

        return effectiveByCategory
            .map { category, effectiveML in
                TypeSlice(categoryName: category, effectiveML: effectiveML, rawML: rawByCategory[category] ?? 0)
            }
            .sorted { $0.effectiveML > $1.effectiveML }
    }

    /// `min(100, ...)`-free intensity bin for one day's consumed/goal ratio:
    /// 0 when there's no consumption at all (not just a low ratio), then
    /// quartile bins 1-4 for `(0, 0.25], (0.25, 0.5], (0.5, 0.75], (0.75, ∞)`
    /// — the last bin is open-ended rather than capped at 1.0 so a
    /// goal-exceeding day still reads as the darkest cell instead of falling
    /// off the scale. Zero (not a crash) when `goalML` is non-positive, same
    /// convention as `Awards.dailyScore`.
    static func heatmapIntensity(consumedML: Double, goalML: Double) -> Int {
        guard goalML > 0, consumedML > 0 else { return 0 }
        let ratio = consumedML / goalML
        if ratio <= 0.25 { return 1 }
        if ratio <= 0.5 { return 2 }
        if ratio <= 0.75 { return 3 }
        return 4
    }

    /// Last `weekCount` calendar weeks (oldest first) ending on the week
    /// containing `endingOn`, as a week-major grid: each inner array is one
    /// week's 7 days in `calendar` order, `nil` for any slot that falls
    /// after `endingOn` (only possible in the final, current week). `days`
    /// should be the full unwindowed history, same as `rangeTotals`.
    static func heatmapWeeks(
        days: [DailyTotal], weekCount: Int = 12, endingOn: Date, calendar: Calendar, goalML: Double
    ) -> [[HeatmapCell?]] {
        let totalsByDay = Dictionary(uniqueKeysWithValues: days.map { (calendar.startOfDay(for: $0.day), $0.totalML) })
        let today = calendar.startOfDay(for: endingOn)
        guard let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start,
              let firstWeekStart = calendar.date(byAdding: .weekOfYear, value: -(weekCount - 1), to: currentWeekStart)
        else { return [] }

        return (0..<weekCount).map { weekIndex -> [HeatmapCell?] in
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: weekIndex, to: firstWeekStart) else {
                return Array(repeating: nil, count: 7)
            }
            return (0..<7).map { dayIndex -> HeatmapCell? in
                guard let day = calendar.date(byAdding: .day, value: dayIndex, to: weekStart), day <= today else {
                    return nil
                }
                let consumedML = totalsByDay[day] ?? 0
                return HeatmapCell(day: day, intensity: heatmapIntensity(consumedML: consumedML, goalML: goalML))
            }
        }
    }

    /// RFC-4180 CSV of every sip, oldest first: `date,drink,category,
    /// raw_ml,hydration_factor,effective_ml,source`. Dates are ISO-8601;
    /// `source` is `manual` or `coaster`. ml/factor fields are fixed to 2
    /// decimal places — plain `Double` text can render float noise (e.g.
    /// 350 * 0.85 as `297.49999999999994`) and the whole catalog's
    /// hydration factors already fit in 2 decimals.
    static func csv(sips: [SipRecord]) -> String {
        let header = "date,drink,category,raw_ml,hydration_factor,effective_ml,source\n"
        let isoFormatter = ISO8601DateFormatter()
        let rows = sips
            .sorted { $0.date < $1.date }
            .map { sip -> String in
                let drink = DrinkCatalog.drink(for: sip.typeID)
                let fields = [
                    isoFormatter.string(from: sip.date),
                    drink.name,
                    drink.category.rawValue,
                    String(format: "%.2f", sip.grams),
                    String(format: "%.2f", sip.hydrationFactor),
                    String(format: "%.2f", sip.effectiveGrams),
                    sip.isManual ? "manual" : "coaster",
                ]
                return fields.map(csvField).joined(separator: ",") + "\n"
            }
        return header + rows.joined()
    }

    /// Quotes a single CSV field per RFC-4180 when it contains a comma,
    /// quote, or newline — doubling any embedded quotes. Catalog drink/
    /// category names contain none of these today, but every field routes
    /// through this so that stays true even if that ever changes.
    static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Week or month range for the History chart/breakdown toggle.
enum HistoryRange: CaseIterable, Hashable, Sendable {
    case week
    case month

    var days: Int {
        switch self {
        case .week: return 7
        case .month: return 30
        }
    }

    var label: String {
        switch self {
        case .week: return "Week"
        case .month: return "Month"
        }
    }
}

/// One drink category's totals for the "By drink" breakdown, sorted by
/// `effectiveML` descending.
struct TypeSlice: Equatable, Sendable {
    let categoryName: String
    let effectiveML: Double
    let rawML: Double
}

/// One heatmap grid cell: a calendar day and its 0-4 intensity bin (see
/// `Analytics.heatmapIntensity`).
struct HeatmapCell: Equatable, Sendable {
    let day: Date
    let intensity: Int
}
