import Foundation
import Testing

@testable import HydraCoaster

struct AwardsTests {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2 // Monday - matches the "Mon-Sun" week the perfect-week badge uses
        return cal
    }()

    /// Fixed date (no `Date()`) in January 2026 unless overridden — Jan 5,
    /// 2026 is a Monday, which the perfect-week tests below rely on.
    private func date(_ day: Int, month: Int = 1, year: Int = 2026, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// Midnight for the given day — every earned date `Awards` reports is a
    /// `calendar.startOfDay`, so assertions compare against this rather than
    /// `date(_:)`'s noon default.
    private func day(_ day: Int, month: Int = 1, year: Int = 2026) -> Date {
        calendar.startOfDay(for: date(day, month: month, year: year))
    }

    private func totals(_ pairs: [(Int, Double)]) -> [DailyTotal] {
        pairs.map { DailyTotal(day: date($0.0), totalML: $0.1) }
    }

    private func sip(_ day: Int, hour: Int = 12, grams: Double = 500, seq: Int = 1) -> SipRecord {
        SipRecord(seq: seq, date: date(day, hour: hour), grams: grams, isEstimatedDate: false)
    }

    // MARK: - dailyScore

    @Test func dailyScore_zeroGoal_returnsZero() {
        #expect(Awards.dailyScore(consumedML: 500, goalML: 0) == 0)
    }

    @Test func dailyScore_negativeGoal_returnsZero() {
        #expect(Awards.dailyScore(consumedML: 500, goalML: -100) == 0)
    }

    @Test func dailyScore_overGoal_capsAt100() {
        #expect(Awards.dailyScore(consumedML: 3000, goalML: 2000) == 100)
    }

    @Test func dailyScore_exactGoal_returns100() {
        #expect(Awards.dailyScore(consumedML: 2000, goalML: 2000) == 100)
    }

    @Test func dailyScore_partial_roundsToNearestPercent() {
        // 1030/2000 = 51.5% -> rounds away from zero to 52
        #expect(Awards.dailyScore(consumedML: 1030, goalML: 2000) == 52)
    }

    // MARK: - currentStreak

    @Test func currentStreak_incompleteToday_doesNotBreakStreakThroughYesterday() {
        let today = date(20)
        let days = totals([(17, 2000), (18, 2000), (19, 2000), (20, 500)])
        #expect(Awards.currentStreak(days: days, goalML: 2000, today: today, calendar: calendar) == 3)
    }

    @Test func currentStreak_completeToday_counts() {
        let today = date(20)
        let days = totals([(18, 2000), (19, 2000), (20, 2000)])
        #expect(Awards.currentStreak(days: days, goalML: 2000, today: today, calendar: calendar) == 3)
    }

    @Test func currentStreak_gapBreaksStreak() {
        let today = date(20)
        let days = totals([(17, 2000), (18, 500), (19, 2000), (20, 2000)]) // miss on day 18
        #expect(Awards.currentStreak(days: days, goalML: 2000, today: today, calendar: calendar) == 2)
    }

    @Test func currentStreak_noHistory_isZero() {
        #expect(Awards.currentStreak(days: [], goalML: 2000, today: date(20), calendar: calendar) == 0)
    }

    @Test func currentStreak_zeroGoal_isZero() {
        let days = totals([(20, 2000)])
        #expect(Awards.currentStreak(days: days, goalML: 0, today: date(20), calendar: calendar) == 0)
    }

    // MARK: - longestStreak

    @Test func longestStreak_findsLongestRunAcrossHistory() {
        let days = totals([
            (1, 2000), (2, 2000), // 2-day run
            (4, 2000), (5, 2000), (6, 2000), (7, 2000), // 4-day run (longest)
            (10, 2000),
        ])
        #expect(Awards.longestStreak(days: days, goalML: 2000, calendar: calendar) == 4)
    }

    @Test func longestStreak_noQualifyingDays_isZero() {
        let days = totals([(1, 500), (2, 800)])
        #expect(Awards.longestStreak(days: days, goalML: 2000, calendar: calendar) == 0)
    }

    @Test func longestStreak_ignoresIncompleteTodayRuleUnlikeCurrentStreak() {
        // longestStreak has no "today is still in progress" carve-out —
        // a run is a run regardless of where `today` sits.
        let days = totals([(1, 2000), (2, 2000), (3, 2000)])
        #expect(Awards.longestStreak(days: days, goalML: 2000, calendar: calendar) == 3)
    }

    // MARK: - Badge catalog shape

    @Test func catalog_hasTenBadgesWithUniqueIDs() {
        #expect(Awards.catalog.count == 10)
        #expect(Set(Awards.catalog.map(\.id)).count == 10)
    }

    // MARK: - earnedBadges: first-sip / first-goal

    @Test func earnedBadges_noSips_noneEarned() {
        #expect(Awards.earnedBadges(sips: [], days: [], goalML: 2000, calendar: calendar).isEmpty)
    }

    @Test func earnedBadges_firstSip_earnedOnFirstLoggedSipsDay() {
        let sips = [sip(10, seq: 1), sip(5, seq: 2)] // unordered input, day 5 is chronologically first
        let earned = Awards.earnedBadges(sips: sips, days: [], goalML: 2000, calendar: calendar)
        #expect(earned["first-sip"] == day(5))
    }

    @Test func earnedBadges_firstGoal_earnedOnFirstDayHittingGoal() {
        let sips = [sip(1, grams: 500, seq: 1), sip(3, grams: 2000, seq: 2)]
        let days = totals([(1, 500), (3, 2000)])
        let earned = Awards.earnedBadges(sips: sips, days: days, goalML: 2000, calendar: calendar)
        #expect(earned["first-goal"] == day(3))
    }

    @Test func earnedBadges_firstGoal_notEarnedWhenGoalNeverHit() {
        let sips = [sip(1, grams: 500, seq: 1)]
        let days = totals([(1, 500)])
        let earned = Awards.earnedBadges(sips: sips, days: days, goalML: 2000, calendar: calendar)
        #expect(earned["first-goal"] == nil)
    }

    // MARK: - earnedBadges: streaks

    @Test func earnedBadges_streak7_earnedOnSeventhConsecutiveGoalDay() {
        let days = totals((1...7).map { ($0, 2000.0) })
        let earned = Awards.earnedBadges(sips: [sip(1)], days: days, goalML: 2000, calendar: calendar)
        #expect(earned["streak-3"] == day(3))
        #expect(earned["streak-7"] == day(7))
        #expect(earned["streak-14"] == nil)
        #expect(earned["streak-30"] == nil)
    }

    @Test func earnedBadges_streak3_notEarnedWithOnlyTwoConsecutiveDays() {
        let days = totals([(1, 2000), (2, 2000)])
        let earned = Awards.earnedBadges(sips: [sip(1)], days: days, goalML: 2000, calendar: calendar)
        #expect(earned["streak-3"] == nil)
    }

    // MARK: - earnedBadges: sips-100 (Century)

    @Test func earnedBadges_sips100_earnedOnTheHundredthSip() {
        let sips = (1...100).map { sip(1, grams: 10, seq: $0) }
        let earned = Awards.earnedBadges(sips: sips, days: [], goalML: 2000, calendar: calendar)
        #expect(earned["sips-100"] == day(1))
    }

    @Test func earnedBadges_sips100_notEarnedWithFewerThanAHundredSips() {
        let sips = (1...99).map { sip(1, grams: 10, seq: $0) }
        let earned = Awards.earnedBadges(sips: sips, days: [], goalML: 2000, calendar: calendar)
        #expect(earned["sips-100"] == nil)
    }

    // MARK: - earnedBadges: liters-50 (Deep Reservoir)

    @Test func earnedBadges_liters50_earnedWhenCumulativeEffectiveVolumeCrosses50000() {
        let sips = [sip(1, grams: 30_000, seq: 1), sip(2, grams: 25_000, seq: 2)]
        let earned = Awards.earnedBadges(sips: sips, days: [], goalML: 2000, calendar: calendar)
        #expect(earned["liters-50"] == day(2))
    }

    @Test func earnedBadges_liters50_notEarnedBelowThreshold() {
        let sips = [sip(1, grams: 10_000, seq: 1)]
        let earned = Awards.earnedBadges(sips: sips, days: [], goalML: 2000, calendar: calendar)
        #expect(earned["liters-50"] == nil)
    }

    // MARK: - earnedBadges: early-bird

    @Test func earnedBadges_earlyBird_earnedForSipBeforeEightAM() {
        let sips = [sip(1, hour: 6, seq: 1)]
        let earned = Awards.earnedBadges(sips: sips, days: [], goalML: 2000, calendar: calendar)
        #expect(earned["early-bird"] == day(1))
    }

    @Test func earnedBadges_earlyBird_notEarnedWhenNoSipBeforeEightAM() {
        let sips = [sip(1, hour: 9, seq: 1)]
        let earned = Awards.earnedBadges(sips: sips, days: [], goalML: 2000, calendar: calendar)
        #expect(earned["early-bird"] == nil)
    }

    // MARK: - earnedBadges: perfect-week

    @Test func earnedBadges_perfectWeek_earnedWhenAllSevenDaysOfACalendarWeekHitGoal() {
        // Jan 5-11, 2026 is a full Mon-Sun week under firstWeekday = Monday.
        let days = totals((5...11).map { ($0, 2000.0) })
        let earned = Awards.earnedBadges(sips: [sip(5)], days: days, goalML: 2000, calendar: calendar)
        #expect(earned["perfect-week"] == day(11))
    }

    @Test func earnedBadges_perfectWeek_notEarnedWhenGoalDaysSpanTwoCalendarWeeks() {
        // Jan 1-4 (Thu-Sun, tail of the prior Mon-Sun week) + Jan 5-7
        // (Mon-Wed, start of the next) = 7 goal days total, but split across
        // two calendar weeks so neither one completes.
        let days = totals((1...7).map { ($0, 2000.0) })
        let earned = Awards.earnedBadges(sips: [sip(1)], days: days, goalML: 2000, calendar: calendar)
        #expect(earned["perfect-week"] == nil)
    }
}
