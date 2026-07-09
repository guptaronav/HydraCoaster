import Foundation
import Testing

@testable import HydraCoaster

struct AnalyticsTests {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2 // Monday, matching Awards' week convention
        return cal
    }()

    /// Fixed date (no `Date()`) in January 2026 unless overridden.
    private func date(_ day: Int, month: Int = 1, year: Int = 2026, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func day(_ day: Int, month: Int = 1, year: Int = 2026) -> Date {
        calendar.startOfDay(for: date(day, month: month, year: year))
    }

    private func totals(_ pairs: [(Int, Double)]) -> [DailyTotal] {
        pairs.map { DailyTotal(day: date($0.0), totalML: $0.1) }
    }

    private func sipRecord(
        day: Int, grams: Double, typeID: String = "water", seq: Int = 1, hour: Int = 12, isManual: Bool = false
    ) -> SipRecord {
        let drink = DrinkCatalog.drink(for: typeID)
        return SipRecord(
            seq: seq, date: date(day, hour: hour), grams: grams, isEstimatedDate: false,
            typeID: typeID, hydrationFactor: drink.hydrationFactor, isManual: isManual
        )
    }

    // MARK: - HistoryRange

    @Test func historyRange_week_isSevenDays() {
        #expect(HistoryRange.week.days == 7)
    }

    @Test func historyRange_month_isThirtyDays() {
        #expect(HistoryRange.month.days == 30)
    }

    // MARK: - rangeTotals

    @Test func rangeTotals_week_zeroFillsDaysWithNoSips() {
        let today = date(20)
        let days = totals([(14, 500), (15, 1000)])
        let result = Analytics.rangeTotals(days: days, range: .week, endingOn: today, calendar: calendar)
        #expect(result.count == 7)
        #expect(result.map(\.day) == (14...20).map { day($0) })
        #expect(result[0].totalML == 500) // day 14
        #expect(result[1].totalML == 1000) // day 15
        #expect(result[2].totalML == 0) // day 16, zero-filled
    }

    @Test func rangeTotals_week_includesDayExactlySixBack() {
        // "N-1 back included": for a 7-day window that's today - 6.
        let today = date(20)
        let days = totals([(14, 777)])
        let result = Analytics.rangeTotals(days: days, range: .week, endingOn: today, calendar: calendar)
        #expect(result.first?.day == day(14))
        #expect(result.first?.totalML == 777)
    }

    @Test func rangeTotals_week_excludesDayExactlySevenBack() {
        let today = date(20)
        let days = totals([(13, 999)]) // today - 7, one day outside the window
        let result = Analytics.rangeTotals(days: days, range: .week, endingOn: today, calendar: calendar)
        #expect(result.map(\.day).contains(day(13)) == false)
        #expect(result.reduce(0) { $0 + $1.totalML } == 0)
    }

    @Test func rangeTotals_month_returnsThirtyDaysEndingToday() {
        let today = date(30)
        let result = Analytics.rangeTotals(days: [], range: .month, endingOn: today, calendar: calendar)
        #expect(result.count == 30)
        #expect(result.last?.day == day(30))
    }

    // MARK: - typeBreakdown

    @Test func typeBreakdown_aggregatesByCategorySortedByEffectiveMLDescending() {
        let today = date(10)
        let sips = [
            sipRecord(day: 10, grams: 500, typeID: "water", seq: 1),
            sipRecord(day: 9, grams: 300, typeID: "coffee.black", seq: 2),
            sipRecord(day: 8, grams: 200, typeID: "coffee.black", seq: 3),
        ]
        let slices = Analytics.typeBreakdown(sips: sips, range: .week, endingOn: today, calendar: calendar)
        #expect(slices.count == 2)
        #expect(slices[0].categoryName == "Water & Infusions")
        #expect(slices[0].effectiveML == 500)
        #expect(slices[0].rawML == 500)
        #expect(slices[1].categoryName == "Coffee")
        #expect(slices[1].rawML == 500) // 300 + 200
        #expect(slices[1].effectiveML == 450) // (300 + 200) * 0.9
    }

    @Test func typeBreakdown_defaultTypeID_resolvesToWaterCategory() {
        let today = date(1)
        let sips = [SipRecord(seq: 1, date: date(1), grams: 500, isEstimatedDate: false)]
        let slices = Analytics.typeBreakdown(sips: sips, range: .week, endingOn: today, calendar: calendar)
        #expect(slices.count == 1)
        #expect(slices[0].categoryName == DrinkCatalog.water.category.rawValue)
    }

    @Test func typeBreakdown_unrecognizedTypeID_fallsBackToWaterCategory() {
        let today = date(1)
        let sips = [
            SipRecord(seq: 1, date: date(1), grams: 500, isEstimatedDate: false, typeID: "not-a-real-id", hydrationFactor: 1.0),
        ]
        let slices = Analytics.typeBreakdown(sips: sips, range: .week, endingOn: today, calendar: calendar)
        #expect(slices[0].categoryName == DrinkCatalog.water.category.rawValue)
    }

    @Test func typeBreakdown_excludesSipsOutsideRange() {
        let today = date(20)
        let sips = [sipRecord(day: 12, grams: 500, typeID: "water", seq: 1)] // today - 8, outside the week window
        let slices = Analytics.typeBreakdown(sips: sips, range: .week, endingOn: today, calendar: calendar)
        #expect(slices.isEmpty)
    }

    // MARK: - heatmapIntensity bin boundaries

    @Test func heatmapIntensity_zeroConsumed_isZeroRegardlessOfGoal() {
        #expect(Analytics.heatmapIntensity(consumedML: 0, goalML: 2000) == 0)
    }

    @Test func heatmapIntensity_nonPositiveGoal_isZero() {
        #expect(Analytics.heatmapIntensity(consumedML: 500, goalML: 0) == 0)
        #expect(Analytics.heatmapIntensity(consumedML: 500, goalML: -100) == 0)
    }

    @Test func heatmapIntensity_exactlyQuarter_isBinOne() {
        #expect(Analytics.heatmapIntensity(consumedML: 500, goalML: 2000) == 1) // ratio 0.25
    }

    @Test func heatmapIntensity_justAboveQuarter_isBinTwo() {
        #expect(Analytics.heatmapIntensity(consumedML: 501, goalML: 2000) == 2)
    }

    @Test func heatmapIntensity_exactlyHalf_isBinTwo() {
        #expect(Analytics.heatmapIntensity(consumedML: 1000, goalML: 2000) == 2) // ratio 0.5
    }

    @Test func heatmapIntensity_exactlyThreeQuarters_isBinThree() {
        #expect(Analytics.heatmapIntensity(consumedML: 1500, goalML: 2000) == 3) // ratio 0.75
    }

    @Test func heatmapIntensity_exactlyFullGoal_isBinFour() {
        #expect(Analytics.heatmapIntensity(consumedML: 2000, goalML: 2000) == 4) // ratio 1.0, ">0.75" bucket
    }

    // MARK: - heatmapWeeks grid shape

    @Test func heatmapWeeks_returnsTwelveWeeksOfSevenDaysEach() {
        let today = date(20) // Tuesday, Jan 20 2026
        let weeks = Analytics.heatmapWeeks(days: [], endingOn: today, calendar: calendar, goalML: 2000)
        #expect(weeks.count == 12)
        #expect(weeks.allSatisfy { $0.count == 7 })
    }

    @Test func heatmapWeeks_zeroDataCell_hasIntensityZero() {
        let today = date(20)
        let weeks = Analytics.heatmapWeeks(days: [], endingOn: today, calendar: calendar, goalML: 2000)
        let todayCell = weeks[11].compactMap { $0 }.first { calendar.isDate($0.day, inSameDayAs: today) }
        #expect(todayCell?.intensity == 0)
    }

    @Test func heatmapWeeks_daysAfterEndingOn_areNilInFinalWeek() {
        // Jan 20 2026 is a Tuesday; with a Monday-first week, Jan 21-25 fall
        // later in the same calendar week and haven't happened yet.
        let today = date(20)
        let weeks = Analytics.heatmapWeeks(days: [], endingOn: today, calendar: calendar, goalML: 2000)
        let futureCells = weeks[11].filter { $0 == nil }
        #expect(futureCells.count == 5) // Wed-Sun
    }

    @Test func heatmapWeeks_customWeekCount_isRespected() {
        let today = date(20)
        let weeks = Analytics.heatmapWeeks(days: [], weekCount: 4, endingOn: today, calendar: calendar, goalML: 2000)
        #expect(weeks.count == 4)
    }

    // MARK: - csv

    @Test func csv_emptySips_returnsHeaderOnly() {
        #expect(Analytics.csv(sips: []) == "date,drink,category,raw_ml,hydration_factor,effective_ml,source\n")
    }

    @Test func csv_sortsAscendingByDateWithExactFormattedFields() {
        let sips = [
            sipRecord(day: 6, grams: 350, typeID: "water", seq: 2, hour: 14, isManual: true),
            sipRecord(day: 5, grams: 200, typeID: "coffee.black", seq: 1, hour: 8, isManual: false),
            sipRecord(day: 4, grams: 120, typeID: "tea.green", seq: 3, hour: 20, isManual: false),
        ]
        let expected = """
        date,drink,category,raw_ml,hydration_factor,effective_ml,source
        2026-01-04T20:00:00Z,Green Tea,Tea,120.00,0.95,114.00,coaster
        2026-01-05T08:00:00Z,Black Coffee,Coffee,200.00,0.90,180.00,coaster
        2026-01-06T14:00:00Z,Water,Water & Infusions,350.00,1.00,350.00,manual

        """
        #expect(Analytics.csv(sips: sips) == expected)
    }

    // MARK: - csvField quoting (RFC-4180)

    @Test func csvField_plainValue_isUnchanged() {
        #expect(Analytics.csvField("Black Coffee") == "Black Coffee")
    }

    @Test func csvField_containingComma_isWrappedInQuotes() {
        #expect(Analytics.csvField("Latte, Iced") == "\"Latte, Iced\"")
    }

    @Test func csvField_containingQuote_isWrappedAndEscaped() {
        #expect(Analytics.csvField("12\" Cup") == "\"12\"\" Cup\"")
    }

    @Test func csvField_containingNewline_isWrappedInQuotes() {
        #expect(Analytics.csvField("Two\nLines") == "\"Two\nLines\"")
    }
}
