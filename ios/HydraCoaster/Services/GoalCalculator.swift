import Foundation

/// Pure hydration-goal math (V2-T1). No SwiftData/networking — testable
/// without the app's runtime pieces. `PersonalGoalEditor` uses `baseGoalML`
/// for the live preview; `TodayView` uses `effectiveGoalML` to scale the
/// stored (base) goal by weather.
enum GoalCalculator {
    enum ActivityLevel: Int {
        case sedentary = 0
        case moderate = 1
        case active = 2

        var bonusML: Double {
            switch self {
            case .sedentary: 0
            case .moderate: 350
            case .active: 700
            }
        }
    }

    static let minGoalML: Double = 1200
    static let maxGoalML: Double = 5000
    /// Weather can scale the goal up by at most this much (+20%).
    static let maxWeatherFactor: Double = 1.2

    /// `weightKg * 30 + max(0, heightCm - 160) * 5 + activityBonus`, rounded
    /// to the nearest 50 ml and clamped to [1200, 5000].
    static func baseGoalML(weightKg: Double, heightCm: Double, activityLevel: Int) -> Double {
        let activity = ActivityLevel(rawValue: activityLevel) ?? .moderate
        let raw = weightKg * 30 + max(0, heightCm - 160) * 5 + activity.bonusML
        let rounded = (raw / 50).rounded() * 50
        return min(max(rounded, minGoalML), maxGoalML)
    }

    /// `1 + (1 - reminderFactor) * 0.3`, capped at +20%. `reminderFactor` is
    /// `WeatherService.lastFactor` — `nil` (weather disabled, or no fetch
    /// yet) reads as its baseline of 1.0, i.e. no scaling.
    static func weatherGoalFactor(reminderFactor: Double?) -> Double {
        let factor = reminderFactor ?? 1.0
        return min(1 + (1 - factor) * 0.3, maxWeatherFactor)
    }

    /// The base goal scaled by weather, rounded to the nearest 50 ml.
    static func effectiveGoalML(base: Double, reminderFactor: Double?) -> Double {
        let scaled = base * weatherGoalFactor(reminderFactor: reminderFactor)
        return (scaled / 50).rounded() * 50
    }
}
