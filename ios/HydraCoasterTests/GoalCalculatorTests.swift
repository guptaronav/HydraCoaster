import Testing

@testable import HydraCoaster

struct GoalCalculatorTests {

    // MARK: - baseGoalML(weightKg:heightCm:activityLevel:)

    @Test func baseGoal_heightBelow160_contributesNoHeightBonus() {
        // 50*30 + 0 + 0 = 1500
        #expect(GoalCalculator.baseGoalML(weightKg: 50, heightCm: 150, activityLevel: 0) == 1500)
    }

    @Test func baseGoal_heightExactly160_contributesNoHeightBonus() {
        // 40*30 + 0 + 0 = 1200 — also the floor clamp boundary.
        #expect(GoalCalculator.baseGoalML(weightKg: 40, heightCm: 160, activityLevel: 0) == 1200)
    }

    @Test func baseGoal_moderateActivity_addsBonus() {
        // 60*30 + (170-160)*5 + 350 = 1800 + 50 + 350 = 2200
        #expect(GoalCalculator.baseGoalML(weightKg: 60, heightCm: 170, activityLevel: 1) == 2200)
    }

    @Test func baseGoal_activeActivity_addsLargerBonus() {
        // 70*30 + (180-160)*5 + 700 = 2100 + 100 + 700 = 2900
        #expect(GoalCalculator.baseGoalML(weightKg: 70, heightCm: 180, activityLevel: 2) == 2900)
    }

    @Test func baseGoal_roundsDownToNearest50() {
        // 61*30 + (165-160)*5 = 1830 + 25 = 1855 -> 1850
        #expect(GoalCalculator.baseGoalML(weightKg: 61, heightCm: 165, activityLevel: 0) == 1850)
    }

    @Test func baseGoal_roundsUpAtExactHalfway() {
        // 62.5*30 = 1875, exactly between 1850 and 1900 -> rounds away from zero to 1900
        #expect(GoalCalculator.baseGoalML(weightKg: 62.5, heightCm: 160, activityLevel: 0) == 1900)
    }

    @Test func baseGoal_belowFloor_clampsTo1200() {
        // 10*30 = 300, far under the floor
        #expect(GoalCalculator.baseGoalML(weightKg: 10, heightCm: 100, activityLevel: 0) == 1200)
    }

    @Test func baseGoal_aboveCeiling_clampsTo5000() {
        // 200*30 + (220-160)*5 + 700 = 6000 + 300 + 700 = 7000, far over the ceiling
        #expect(GoalCalculator.baseGoalML(weightKg: 200, heightCm: 220, activityLevel: 2) == 5000)
    }

    @Test func baseGoal_unknownActivityLevel_fallsBackToModerate() {
        // Defensive: a persisted value outside 0/1/2 (e.g. from a future app
        // version) reads as moderate rather than crashing or going 0.
        #expect(GoalCalculator.baseGoalML(weightKg: 50, heightCm: 160, activityLevel: 5) == 1850)
    }

    // MARK: - weatherGoalFactor(reminderFactor:)

    @Test func weatherFactor_nilReminderFactor_isBaseline() {
        #expect(GoalCalculator.weatherGoalFactor(reminderFactor: nil) == 1.0)
    }

    @Test func weatherFactor_reminderFactorOne_isBaseline() {
        #expect(GoalCalculator.weatherGoalFactor(reminderFactor: 1.0) == 1.0)
    }

    @Test func weatherFactor_warm_scalesUp() {
        // 1 + (1 - 0.75) * 0.3 = 1.075
        #expect(GoalCalculator.weatherGoalFactor(reminderFactor: 0.75) == 1.075)
    }

    @Test func weatherFactor_hot_scalesUpMore() {
        // 1 + (1 - 0.5) * 0.3 = 1.15
        #expect(GoalCalculator.weatherGoalFactor(reminderFactor: 0.5) == 1.15)
    }

    @Test func weatherFactor_hotAndDry_scalesUpButUnderCap() {
        // 1 + (1 - 0.425) * 0.3 = 1.1725 (~+17%), below the +20% cap
        let factor = GoalCalculator.weatherGoalFactor(reminderFactor: 0.425)
        #expect(abs(factor - 1.1725) < 0.0001)
    }

    @Test func weatherFactor_belowAnyRealFactor_clampsToTwentyPercentCap() {
        // reminderFactor 0.0 is outside what WeatherService actually
        // produces (floor is 0.425), but the function stays pure/defensive.
        #expect(GoalCalculator.weatherGoalFactor(reminderFactor: 0.0) == 1.2)
    }

    // MARK: - effectiveGoalML(base:reminderFactor:)

    @Test func effectiveGoal_noWeatherScaling_returnsBaseUnchanged() {
        #expect(GoalCalculator.effectiveGoalML(base: 2000, reminderFactor: nil) == 2000)
    }

    @Test func effectiveGoal_hotAndDry_scalesAndRoundsToNearest50() {
        // 2000 * 1.1725 = 2345 -> nearest 50 is 2350
        #expect(GoalCalculator.effectiveGoalML(base: 2000, reminderFactor: 0.425) == 2350)
    }

    @Test func effectiveGoal_atCap_scalesByExactlyTwentyPercent() {
        // 1500 * 1.2 = 1800, already a multiple of 50
        #expect(GoalCalculator.effectiveGoalML(base: 1500, reminderFactor: 0.0) == 1800)
    }
}
