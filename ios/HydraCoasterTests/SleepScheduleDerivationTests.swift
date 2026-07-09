import Foundation
import Testing

@testable import HydraCoaster

struct SleepScheduleDerivationTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour, minute: minute))!
    }

    /// One "night" of `hours` duration, bed-start at `day hour:minute`.
    private func night(day: Int, hour: Int, minute: Int, hours: Double) -> DateInterval {
        let start = date(day, hour, minute)
        return DateInterval(start: start, end: start.addingTimeInterval(hours * 3600))
    }

    // MARK: - mergeIntoNights

    @Test func mergeIntoNights_overlappingIntervals_mergeIntoOne() {
        let a = DateInterval(start: date(1, 23, 0), end: date(2, 2, 0))
        let b = DateInterval(start: date(2, 1, 30), end: date(2, 3, 0)) // overlaps a
        let merged = SleepScheduleDerivation.mergeIntoNights([a, b])
        #expect(merged.count == 1)
        #expect(merged.first?.start == a.start)
        #expect(merged.first?.end == b.end)
    }

    @Test func mergeIntoNights_adjacentIntervals_mergeIntoOne() {
        let a = DateInterval(start: date(1, 23, 0), end: date(2, 1, 0))
        let b = DateInterval(start: date(2, 1, 0), end: date(2, 3, 0)) // touches a exactly
        let merged = SleepScheduleDerivation.mergeIntoNights([a, b])
        #expect(merged.count == 1)
        #expect(merged.first?.end == b.end)
    }

    @Test func mergeIntoNights_disjointIntervals_stayApart() {
        let a = DateInterval(start: date(1, 23, 0), end: date(2, 3, 0))
        let b = DateInterval(start: date(2, 23, 0), end: date(3, 3, 0))
        let merged = SleepScheduleDerivation.mergeIntoNights([a, b])
        #expect(merged.count == 2)
    }

    // MARK: - deriveWindow: nap exclusion

    @Test func deriveWindow_nightsUnderThreeHours_dontCountTowardMinimum() {
        // Two real nights + one 1h nap: after the length filter, only 2
        // nights qualify — below the 3-night minimum, so nil even though
        // 3 sessions existed before filtering.
        let intervals = [
            night(day: 1, hour: 22, minute: 0, hours: 8),
            night(day: 2, hour: 22, minute: 0, hours: 8),
            night(day: 3, hour: 14, minute: 0, hours: 1), // afternoon nap
        ]
        #expect(SleepScheduleDerivation.deriveWindow(from: intervals, calendar: calendar) == nil)
    }

    @Test func deriveWindow_napAmongThreeRealNights_isExcludedButStillDerives() {
        let intervals = [
            night(day: 1, hour: 22, minute: 0, hours: 8),
            night(day: 2, hour: 22, minute: 0, hours: 8),
            night(day: 3, hour: 22, minute: 0, hours: 8),
            night(day: 4, hour: 14, minute: 0, hours: 1), // afternoon nap, excluded
        ]
        let result = SleepScheduleDerivation.deriveWindow(from: intervals, calendar: calendar)
        #expect(result?.startMin == 22 * 60)
        #expect(result?.endMin == 6 * 60) // 22:00 + 8h = 06:00
    }

    // MARK: - deriveWindow: <3 nights -> nil

    @Test func deriveWindow_fewerThanThreeQualifyingNights_isNil() {
        let intervals = [
            night(day: 1, hour: 22, minute: 0, hours: 8),
            night(day: 2, hour: 22, minute: 0, hours: 8),
        ]
        #expect(SleepScheduleDerivation.deriveWindow(from: intervals, calendar: calendar) == nil)
    }

    // MARK: - deriveWindow: median, odd vs even night counts

    @Test func deriveWindow_oddNightCount_medianIsMiddleValue() {
        let intervals = [
            night(day: 1, hour: 22, minute: 0, hours: 8),
            night(day: 2, hour: 22, minute: 10, hours: 8),
            night(day: 3, hour: 22, minute: 20, hours: 8),
        ]
        let result = SleepScheduleDerivation.deriveWindow(from: intervals, calendar: calendar)
        #expect(result?.startMin == 22 * 60 + 10)
    }

    @Test func deriveWindow_evenNightCount_medianAveragesTwoMiddleValues() {
        let intervals = [
            night(day: 1, hour: 22, minute: 0, hours: 8),
            night(day: 2, hour: 22, minute: 10, hours: 8),
            night(day: 3, hour: 22, minute: 20, hours: 8),
            night(day: 4, hour: 22, minute: 30, hours: 8),
        ]
        let result = SleepScheduleDerivation.deriveWindow(from: intervals, calendar: calendar)
        #expect(result?.startMin == 22 * 60 + 15) // average of 22:10 and 22:20
    }

    // MARK: - deriveWindow: midnight-spanning bed times

    @Test func deriveWindow_bedTimesStraddlingMidnight_medianStaysNearMidnightNotNoon() {
        // Bed times 23:50, 23:55, 00:05, 00:10 — a naive minute-of-day
        // median (no shift) would average the two chronological middle
        // values (00:10 and 23:50 as raw minutes 10 and 1430) into ~noon,
        // which is nowhere near any actual bedtime. The correct answer,
        // shifting the domain before taking the median, is ~00:00.
        let intervals = [
            night(day: 1, hour: 23, minute: 50, hours: 4),
            night(day: 3, hour: 23, minute: 55, hours: 4),
            night(day: 5, hour: 0, minute: 5, hours: 4),
            night(day: 6, hour: 0, minute: 10, hours: 4),
        ]
        let result = SleepScheduleDerivation.deriveWindow(from: intervals, calendar: calendar)
        #expect(result?.startMin == 0)
    }
}
