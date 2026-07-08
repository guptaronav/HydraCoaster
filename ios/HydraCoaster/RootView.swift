import SwiftUI

/// Top-level tab shell. Shows onboarding as a full-screen cover until the
/// user finishes it once; T3/T4's TodayView plugs in unchanged.
struct RootView: View {
    var client: CoasterClient
    var syncEngine: SyncEngine

    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var selectedTab: Tab = Self.initialTab

    private enum Tab: Int {
        case today, history, settings
    }

    #if DEBUG
    /// Screenshot aid only: `HC_INITIAL_TAB=0|1|2` selects a tab at launch
    /// so the gate can capture each one without simulating taps.
    private static var initialTab: Tab {
        guard let raw = ProcessInfo.processInfo.environment["HC_INITIAL_TAB"],
              let value = Int(raw), let tab = Tab(rawValue: value) else { return .today }
        return tab
    }
    #else
    private static let initialTab: Tab = .today
    #endif

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                TodayView(client: client, syncEngine: syncEngine)
            }
            .tabItem { Label("Today", systemImage: "drop.fill") }
            .tag(Tab.today)

            NavigationStack {
                HistoryView()
            }
            .tabItem { Label("History", systemImage: "chart.bar.fill") }
            .tag(Tab.history)

            NavigationStack {
                SettingsView(client: client)
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            .tag(Tab.settings)
        }
        .tint(.hydraAccent)
        .fullScreenCover(isPresented: onboardingBinding) {
            OnboardingFlow(client: client) { hasOnboarded = true }
        }
    }

    private var onboardingBinding: Binding<Bool> {
        Binding(get: { !hasOnboarded }, set: { hasOnboarded = !$0 })
    }
}
