import SwiftData
import SwiftUI

@main
struct HydraCoasterApp: App {
    @State private var client = CoasterClient()
    @State private var syncEngine: SyncEngine
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
        _syncEngine = State(initialValue: SyncEngine(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView(client: client, syncEngine: syncEngine)
        }
        .modelContainer(modelContainer)
    }
}
