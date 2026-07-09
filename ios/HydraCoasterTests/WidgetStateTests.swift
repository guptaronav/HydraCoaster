import Foundation
import SwiftUI
import Testing

@testable import HydraCoaster

struct WidgetStateTests {
    private func state(consumedML: Double, goalML: Double, streak: Int = 0) -> WidgetState {
        WidgetState(consumedML: consumedML, goalML: goalML, streak: streak, themeRaw: Theme.aqua.rawValue, updatedAt: Date())
    }

    // MARK: - progress

    @Test func progress_zeroGoal_isZero() {
        #expect(state(consumedML: 500, goalML: 0).progress == 0)
    }

    @Test func progress_negativeGoal_isZero() {
        #expect(state(consumedML: 500, goalML: -100).progress == 0)
    }

    @Test func progress_belowGoal_isFraction() {
        #expect(state(consumedML: 1000, goalML: 2000).progress == 0.5)
    }

    @Test func progress_atGoal_isOne() {
        #expect(state(consumedML: 2000, goalML: 2000).progress == 1.0)
    }

    @Test func progress_overGoal_isCappedAtOne() {
        #expect(state(consumedML: 3000, goalML: 2000).progress == 1.0)
    }

    // MARK: - JSON round-trip via an injected UserDefaults suite

    @Test func saveThenLoad_roundTripsThroughInjectedSuite() {
        let suiteName = "test-widget-state-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let original = state(consumedML: 1234, goalML: 2000, streak: 5)
        WidgetStateStore.save(original, to: defaults)
        let loaded = WidgetStateStore.load(from: defaults)

        #expect(loaded == original)
    }

    @Test func load_emptySuite_isNil() {
        let suiteName = "test-widget-state-empty-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        #expect(WidgetStateStore.load(from: defaults) == nil)
    }

    @Test func save_overwritesPreviousValue() {
        let suiteName = "test-widget-state-overwrite-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        WidgetStateStore.save(state(consumedML: 100, goalML: 2000), to: defaults)
        WidgetStateStore.save(state(consumedML: 900, goalML: 2000), to: defaults)

        #expect(WidgetStateStore.load(from: defaults)?.consumedML == 900)
    }

    // MARK: - Theme

    @Test func theme_defaultRawValue_isAqua() {
        #expect(Theme(rawValue: 0) == .aqua)
    }

    @Test func theme_allCases_rawValuesAreStableZeroThroughThree() {
        #expect(Theme.allCases.map(\.rawValue).sorted() == [0, 1, 2, 3])
        #expect(Theme.aqua.rawValue == 0)
        #expect(Theme.sunset.rawValue == 1)
        #expect(Theme.forest.rawValue == 2)
        #expect(Theme.mono.rawValue == 3)
    }

    // MARK: - Appearance

    @Test func appearance_system_mapsToNilColorScheme() {
        #expect(Appearance.system.colorScheme == nil)
    }

    @Test func appearance_light_mapsToLightColorScheme() {
        #expect(Appearance.light.colorScheme == .light)
    }

    @Test func appearance_dark_mapsToDarkColorScheme() {
        #expect(Appearance.dark.colorScheme == .dark)
    }

    @Test func appearance_defaultRawValue_isSystem() {
        #expect(Appearance(rawValue: 0) == .system)
    }
}
