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
        _client = State(initialValue: client)
        _syncEngine = State(initialValue: engine)
        let context = container.mainContext
        _appServices = State(initialValue: AppServices(
            client: client,
            syncEngine: engine,
            store: store,
            isRemindEnabled: { AppSettings.fetchOrCreate(in: context).remindOn }
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView(client: client, syncEngine: syncEngine, appServices: appServices)
        }
        .modelContainer(modelContainer)
    }
}
