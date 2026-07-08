import Foundation
import Testing

@testable import HydraCoaster

struct DailyTotalsTests {
    private let calendar = Calendar(identifier: .gregorian)

    /// `offset` days from `now`, at `hour`:00, same calendar day semantics
    /// `DailyTotals` itself uses.
    private func day(_ offset: Int, from now: Date, hour: Int = 12) -> Date {
        let shifted = calendar.date(byAdding: .day, value: offset, to: now)!
        let start = calendar.startOfDay(for: shifted)
        return calendar.date(byAdding: .hour, value: hour, to: start)!
    }

    @Test func compute_emptyInput_returns14ZeroFilledDays() {
        let totals = DailyTotals.compute(from: [], endingAt: Date(), calendar: calendar)
        #expect(totals.count == DailyTotals.windowDays)
        #expect(totals.allSatisfy { $0.totalML == 0 })
    }

    @Test func compute_lastBucketIsToday() {
        let now = Date()
        let totals = DailyTotals.compute(from: [], endingAt: now, calendar: calendar)
        #expect(totals.last?.day == calendar.startOfDay(for: now))
    }

    @Test func compute_sumsMultipleSipsWithinSameDay() {
        let now = Date()
        let records = [
            SipRecord(seq: 1, date: day(0, from: now, hour: 8), grams: 100, isEstimatedDate: false),
            SipRecord(seq: 2, date: day(0, from: now, hour: 14), grams: 50, isEstimatedDate: false),
        ]
        let totals = DailyTotals.compute(from: records, endingAt: now, calendar: calendar)
        #expect(totals.last?.totalML == 150)
    }

    @Test func compute_bucketsAcrossDayBoundary() {
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let justBeforeMidnight = calendar.date(byAdding: .second, value: -1, to: todayStart)!
        let justAfterMidnight = calendar.date(byAdding: .second, value: 1, to: todayStart)!

        let records = [
            SipRecord(seq: 1, date: justBeforeMidnight, grams: 10, isEstimatedDate: false),
            SipRecord(seq: 2, date: justAfterMidnight, grams: 20, isEstimatedDate: false),
        ]
        let totals = DailyTotals.compute(from: records, endingAt: now, calendar: calendar)

        #expect(totals[totals.count - 2].totalML == 10) // yesterday
        #expect(totals[totals.count - 1].totalML == 20) // today
    }

    @Test func compute_zeroFillsDaysWithNoSips() {
        let now = Date()
        let records = [SipRecord(seq: 1, date: day(0, from: now), grams: 100, isEstimatedDate: false)]
        let totals = DailyTotals.compute(from: records, endingAt: now, calendar: calendar)
        #expect(totals.dropLast().allSatisfy { $0.totalML == 0 })
    }

    @Test func compute_ignoresSipsOlderThanTheWindow() {
        let now = Date()
        let records = [SipRecord(seq: 1, date: day(-20, from: now), grams: 999, isEstimatedDate: false)]
        let totals = DailyTotals.compute(from: records, endingAt: now, calendar: calendar)
        #expect(totals.reduce(0) { $0 + $1.totalML } == 0)
    }
}
