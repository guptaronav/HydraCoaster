import Foundation

/// Snapshot written by the app after anything that changes what the widget
/// should show (see `AppServices.widgetRelevantSettingsDidChange` and its
/// callers) and read back by the widget extension's timeline provider.
/// Foundation-only — no WidgetKit, SwiftData, or other app-only import — so
/// it compiles unmodified in both the app and widget extension targets, and
/// stays a plain, directly testable value type.
struct WidgetState: Codable, Equatable {
    let consumedML: Double
    let goalML: Double
    let streak: Int
    let themeRaw: Int
    let updatedAt: Date

    /// 0 when there's no real goal to divide by; capped at 1 so the ring
    /// never overshoots visually even once the goal's been exceeded.
    var progress: Double {
        guard goalML > 0 else { return 0 }
        return min(consumedML / goalML, 1.0)
    }
}

/// Reads/writes `WidgetState` as JSON through the shared App Group suite —
/// the only channel between the app process and the widget extension
/// process. Static funcs take a `UserDefaults` parameter (defaulted to the
/// real App Group suite) so tests can inject an isolated suite instead.
enum WidgetStateStore {
    static let appGroupID = "group.com.ronav.HydraCoaster"
    private static let key = "widgetState"

    static func save(_ state: WidgetState, to defaults: UserDefaults = sharedSuite) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }

    static func load(from defaults: UserDefaults = sharedSuite) -> WidgetState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetState.self, from: data)
    }

    /// Falls back to `.standard` only if the App Group suite can't be
    /// opened (e.g. entitlement missing) — keeps save/load from silently
    /// no-oping in that case, at the cost of no longer being shared with
    /// the widget, which is exactly what's actually true then.
    private static var sharedSuite: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }
}
