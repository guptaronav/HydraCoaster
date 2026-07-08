import SwiftUI

@main
struct HydraCoasterApp: App {
    @State private var client = CoasterClient()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ConnectionDebugView(client: client)
            }
        }
    }
}
