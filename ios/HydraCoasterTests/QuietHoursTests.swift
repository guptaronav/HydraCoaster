import Foundation
import Testing

@testable import HydraCoaster

struct QuietHoursTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(hour: Int, minute: Int, day: Int = 15) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    // MARK: - applyQuietWindow

    @Test func applyQuietWindow_beforeWindow_unchanged() {
        let date = date(hour: 21, minute: 0)
        #expect(applyQuietWindow(date: date, startMin: 22 * 60, endMin: 7 * 60, calendar: calendar) == date)
    }

    @Test func applyQuietWindow_disabled_startEqualsEnd_unchanged() {
        let date = date(hour: 23, minute: 30)
        #expect(applyQuietWindow(date: date, startMin: 0, endMin: 0, calendar: calendar) == date)
    }

    @Test func applyQuietWindow_nonWrapping_insideWindow_defersToEndPlus15() {
        // Window 13:00-14:00 (no midnight wrap), a reminder computed at 13:30.
        let date = date(hour: 13, minute: 30)
        let result = applyQuietWindow(date: date, startMin: 13 * 60, endMin: 14 * 60, calendar: calendar)
        #expect(result == self.date(hour: 14, minute: 15))
    }

    @Test func applyQuietWindow_exactlyAtStart_isInsideWindow() {
        let date = date(hour: 22, minute: 0)
        let result = applyQuietWindow(date: date, startMin: 22 * 60, endMin: 7 * 60, calendar: calendar)
        #expect(result == self.date(hour: 7, minute: 15, day: 16))
    }

    @Test func applyQuietWindow_exactlyAtEnd_isOutsideWindow() {
        let date = date(hour: 7, minute: 0)
        #expect(applyQuietWindow(date: date, startMin: 22 * 60, endMin: 7 * 60, calendar: calendar) == date)
    }

    @Test func applyQuietWindow_midnightWrap_preMidnightPortion_defersToNextDayEnd() {
        // 23:30 is in the pre-midnight portion of a 22:00-07:00 window.
        let date = date(hour: 23, minute: 30)
        let result = applyQuietWindow(date: date, startMin: 22 * 60, endMin: 7 * 60, calendar: calendar)
        #expect(result == self.date(hour: 7, minute: 15, day: 16))
    }

    @Test func applyQuietWindow_midnightWrap_postMidnightPortion_defersToSameDayEnd() {
        // 03:00 is in the post-midnight portion of the same window.
        let date = date(hour: 3, minute: 0)
        let result = applyQuietWindow(date: date, startMin: 22 * 60, endMin: 7 * 60, calendar: calendar)
        #expect(result == self.date(hour: 7, minute: 15))
    }

    @Test func applyQuietWindow_midnightWrap_daytimeGap_unchanged() {
        let date = date(hour: 12, minute: 0)
        #expect(applyQuietWindow(date: date, startMin: 22 * 60, endMin: 7 * 60, calendar: calendar) == date)
    }

    // MARK: - localMinutesToUTCMinutes

    @Test func localMinutesToUTCMinutes_positiveOffset_shiftsBackward() {
        // IST (UTC+5:30): local 22:00/07:00 -> UTC 16:30/01:30.
        let ist = TimeZone(identifier: "Asia/Kolkata")!
        let result = localMinutesToUTCMinutes(startMin: 22 * 60, endMin: 7 * 60, at: Date(), timeZone: ist)
        #expect(result.start == 16 * 60 + 30)
        #expect(result.end == 1 * 60 + 30)
    }

    @Test func localMinutesToUTCMinutes_negativeOffset_shiftsForwardAcrossMidnight() {
        // US Pacific standard time (UTC-8): local 22:00 -> UTC 06:00 (+1 day, but we only track minute-of-day).
        let pacific = TimeZone(identifier: "America/Los_Angeles")!
        let winter = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))!
        let result = localMinutesToUTCMinutes(startMin: 22 * 60, endMin: 7 * 60, at: winter, timeZone: pacific)
        #expect(result.start == 6 * 60)
        #expect(result.end == 15 * 60)
    }

    @Test func localMinutesToUTCMinutes_utcTimeZone_isUnchanged() {
        let result = localMinutesToUTCMinutes(startMin: 22 * 60, endMin: 7 * 60, at: Date(), timeZone: .init(identifier: "UTC")!)
        #expect(result.start == 22 * 60)
        #expect(result.end == 7 * 60)
    }

    @Test func localMinutesToUTCMinutes_equalBounds_staysEqual_regardlessOfOffset() {
        // Disabled ("off" mode writes startMin == endMin) must survive
        // conversion as an equal pair too, since the firmware's own
        // inQuietWindow treats any equal pair as disabled.
        let ist = TimeZone(identifier: "Asia/Kolkata")!
        let result = localMinutesToUTCMinutes(startMin: 0, endMin: 0, at: Date(), timeZone: ist)
        #expect(result.start == result.end)
    }
}
