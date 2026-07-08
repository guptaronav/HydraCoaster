import Foundation
import Testing

@testable import HydraCoaster

struct ReminderSchedulerTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func nextReminderDate_noSips_isNil() {
        #expect(nextReminderDate(lastSip: nil, sips: [], intervalS: 1200, now: now) == nil)
    }

    @Test func nextReminderDate_oneSip_noBehaviorFactor_isLastSipPlusInterval() {
        let lastSip = now.addingTimeInterval(-100)
        let sips = [SipRecord(seq: 1, date: lastSip, grams: 50, isEstimatedDate: false)]

        let result = nextReminderDate(lastSip: lastSip, sips: sips, intervalS: 1200, now: now)

        #expect(result == lastSip.addingTimeInterval(1200))
    }

    @Test func nextReminderDate_trailingHourAtOrAbove250g_appliesBehaviorFactor() {
        let lastSip = now.addingTimeInterval(-60)
        let sips = [
            SipRecord(seq: 1, date: now.addingTimeInterval(-30 * 60), grams: 150, isEstimatedDate: false),
            SipRecord(seq: 2, date: lastSip, grams: 100, isEstimatedDate: false),
        ]

        let result = nextReminderDate(lastSip: lastSip, sips: sips, intervalS: 1200, now: now)

        #expect(result == lastSip.addingTimeInterval(1200 * 1.5))
    }

    @Test func nextReminderDate_trailingHourJustBelow250g_noBehaviorFactor() {
        let lastSip = now.addingTimeInterval(-60)
        let sips = [
            SipRecord(seq: 1, date: now.addingTimeInterval(-30 * 60), grams: 149.9, isEstimatedDate: false),
            SipRecord(seq: 2, date: lastSip, grams: 100, isEstimatedDate: false),
        ]

        let result = nextReminderDate(lastSip: lastSip, sips: sips, intervalS: 1200, now: now)

        #expect(result == lastSip.addingTimeInterval(1200))
    }

    @Test func nextReminderDate_oldSipsOutsideTrailingHour_areExcludedFromBehaviorFactor() {
        let lastSip = now.addingTimeInterval(-60)
        let sips = [
            // Well over 250g, but more than 60 min before `now` — shouldn't count.
            SipRecord(seq: 1, date: now.addingTimeInterval(-2 * 60 * 60), grams: 5000, isEstimatedDate: false),
            SipRecord(seq: 2, date: lastSip, grams: 10, isEstimatedDate: false),
        ]

        let result = nextReminderDate(lastSip: lastSip, sips: sips, intervalS: 1200, now: now)

        #expect(result == lastSip.addingTimeInterval(1200))
    }

    @Test func nextReminderDate_sipExactlyAtSixtyMinuteBoundary_isExcluded() {
        let lastSip = now.addingTimeInterval(-10)
        let windowStart = now.addingTimeInterval(-60 * 60) // exactly 60 min ago
        let sips = [
            SipRecord(seq: 1, date: windowStart, grams: 999, isEstimatedDate: false),
            SipRecord(seq: 2, date: lastSip, grams: 10, isEstimatedDate: false),
        ]

        let result = nextReminderDate(lastSip: lastSip, sips: sips, intervalS: 1200, now: now)

        #expect(result == lastSip.addingTimeInterval(1200)) // boundary sip excluded, factor stays 1.0
    }

    @Test func nextReminderDate_computedTimeAlreadyPast_usesTwoMinuteGrace() {
        // Interval of 60s from a sip an hour ago is deep in the past.
        let lastSip = now.addingTimeInterval(-60 * 60)
        let sips = [SipRecord(seq: 1, date: lastSip, grams: 10, isEstimatedDate: false)]

        let result = nextReminderDate(lastSip: lastSip, sips: sips, intervalS: 60, now: now)

        #expect(result == now.addingTimeInterval(120))
    }

    @Test func nextReminderDate_scalesWithInterval() {
        let lastSip = now.addingTimeInterval(-10)
        let sips = [SipRecord(seq: 1, date: lastSip, grams: 10, isEstimatedDate: false)]

        let short = nextReminderDate(lastSip: lastSip, sips: sips, intervalS: 60, now: now)
        let long = nextReminderDate(lastSip: lastSip, sips: sips, intervalS: 14400, now: now)

        #expect(short == lastSip.addingTimeInterval(60))
        #expect(long == lastSip.addingTimeInterval(14400))
    }

    // MARK: - reminderBody

    @Test func reminderBody_underAnHour_reportsMinutes() {
        let lastSip = now.addingTimeInterval(-25 * 60)
        #expect(reminderBody(lastSip: lastSip, at: now) == "It's been 25 min since your last sip.")
    }

    @Test func reminderBody_overAnHour_reportsHours() {
        let lastSip = now.addingTimeInterval(-3 * 60 * 60)
        #expect(reminderBody(lastSip: lastSip, at: now) == "It's been 3 hrs since your last sip.")
    }

    @Test func reminderBody_exactlyOneHour_usesSingularHour() {
        let lastSip = now.addingTimeInterval(-60 * 60)
        #expect(reminderBody(lastSip: lastSip, at: now) == "It's been 1 hr since your last sip.")
    }
}
