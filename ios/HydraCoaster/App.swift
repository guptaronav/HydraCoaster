import SwiftData
import SwiftUI

@main
struct HydraCoasterApp: App {
    @State private var client: CoasterClient
    @State private var syncEngine: SyncEngine
    @State private var appServices: AppServices
    private let modelContainer: ModelContainer

    init() {
        let container: ModelContainer
        do {
            // ponytail: an ephemeral container when hosting the test bundle
            // keeps the app's real store out of test runs (and out of the
            // way of the tests' own containers). Real launches never take
            // this path.
            let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            container = isRunningTests
                ? try ModelContainer.ephemeral()
                : try ModelContainer(for: SipEvent.self, AppSettings.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        modelContainer = container
        let store = SwiftDataSipStore(modelContext: container.mainContext)
        let client = CoasterClient()
        let engine = SyncEngine(store: store)
        let weatherService = WeatherService()
        _client = State(initialValue: client)
        _syncEngine = State(initialValue: engine)
        let context = container.mainContext
        let services = AppServices(
            client: client,
            syncEngine: engine,
            store: store,
            weatherService: weatherService,
            isRemindEnabled: { AppSettings.fetchOrCreate(in: context).remindOn },
            quietHours: {
                let s = AppSettings.fetchOrCreate(in: context)
                return QuietHoursSettings(mode: s.quietMode, startMin: s.quietStartMin, endMin: s.quietEndMin)
            },
            reminderPreset: { AppSettings.fetchOrCreate(in: context).reminderPreset },
            respectFocus: { AppSettings.fetchOrCreate(in: context).respectFocus },
            isFocused: { FocusStatusGate.isFocused },
            saveSleepDerivedWindow: { startMin, endMin in
                let s = AppSettings.fetchOrCreate(in: context)
                s.quietStartMin = startMin
                s.quietEndMin = endMin
                try? context.save()
            },
            baseGoalML: { AppSettings.fetchOrCreate(in: context).goalML },
            themeRaw: { AppSettings.fetchOrCreate(in: context).theme },
            effectiveGoalML: {
                let base = AppSettings.fetchOrCreate(in: context).goalML
                return GoalCalculator.effectiveGoalML(base: base, reminderFactor: weatherService.lastFactor)
            },
            lastCelebratedDay: { AppSettings.fetchOrCreate(in: context).lastCelebratedDay },
            saveCelebratedDay: { day in
                let s = AppSettings.fetchOrCreate(in: context)
                s.lastCelebratedDay = day
                try? context.save()
            }
        )
        _appServices = State(initialValue: services)

        #if DEBUG
        // Screenshot aid only: `HC_SEED_DEMO_SIPS=1` logs a water sip then
        // reclassifies it to coffee, so the gate can capture a
        // reclassified non-water row without simulating any taps.
        if ProcessInfo.processInfo.environment["HC_SEED_DEMO_SIPS"] == "1" {
            engine.logManualSip(drink: DrinkCatalog.water, grams: 350)
            if let seq = store.loadAll().first?.seq {
                services.reclassify(seq: seq, to: DrinkCatalog.drink(for: "coffee.latte"))
            }
        }
        // Screenshot aid only: `HC_QUIET_MODE=0|1|2` pre-sets Quiet Hours'
        // mode so the gate can capture Off/Manual/Sleep without simulating
        // the segmented control — this only sets the stored mode, it never
        // triggers the sleep derivation's lazy HealthKit auth request.
        if let raw = ProcessInfo.processInfo.environment["HC_QUIET_MODE"], let mode = Int(raw) {
            AppSettings.fetchOrCreate(in: context).quietMode = mode
            try? context.save()
        }
        // Screenshot aid only: `HC_THEME=0|1|2|3` pre-sets the color theme
        // (V2-T6) so the gate can capture each swatch's live-recolor effect
        // without simulating a tap on the picker.
        if let raw = ProcessInfo.processInfo.environment["HC_THEME"], let theme = Int(raw) {
            AppSettings.fetchOrCreate(in: context).theme = theme
            try? context.save()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(client: client, syncEngine: syncEngine, appServices: appServices)
        }
        .modelContainer(modelContainer)
    }
}
