import Foundation
import Testing

@testable import HydraCoaster

struct CelebrationTests {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private func date(_ day: Int, month: Int = 1, year: Int = 2026, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func crossingGoal_noPriorCelebration_returnsTrue() {
        #expect(Celebration.shouldCelebrate(
            consumedML: 2100, goalML: 2000, lastCelebrated: nil, now: date(5), calendar: calendar
        ))
    }

    @Test func belowGoal_returnsFalse() {
        #expect(!Celebration.shouldCelebrate(
            consumedML: 1500, goalML: 2000, lastCelebrated: nil, now: date(5), calendar: calendar
        ))
    }

    @Test func zeroGoal_returnsFalse() {
        #expect(!Celebration.shouldCelebrate(
            consumedML: 500, goalML: 0, lastCelebrated: nil, now: date(5), calendar: calendar
        ))
    }

    @Test func negativeGoal_returnsFalse() {
        #expect(!Celebration.shouldCelebrate(
            consumedML: 500, goalML: -100, lastCelebrated: nil, now: date(5), calendar: calendar
        ))
    }

    @Test func sameDayRepeat_returnsFalse() {
        let lastCelebrated = date(5, hour: 9)
        #expect(!Celebration.shouldCelebrate(
            consumedML: 2500, goalML: 2000, lastCelebrated: lastCelebrated, now: date(5, hour: 20), calendar: calendar
        ))
    }

    @Test func nextDay_returnsTrue() {
        let lastCelebrated = date(5)
        #expect(Celebration.shouldCelebrate(
            consumedML: 2100, goalML: 2000, lastCelebrated: lastCelebrated, now: date(6), calendar: calendar
        ))
    }

    @Test func exactEquality_returnsTrue() {
        #expect(Celebration.shouldCelebrate(
            consumedML: 2000, goalML: 2000, lastCelebrated: nil, now: date(5), calendar: calendar
        ))
    }
}
