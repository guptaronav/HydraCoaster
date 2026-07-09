import SwiftUI

/// Top-level tab shell. Shows onboarding as a full-screen cover until the
/// user finishes it once; T3/T4's TodayView plugs in unchanged.
struct RootView: View {
    var client: CoasterClient
    var syncEngine: SyncEngine
    var appServices: AppServices

    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var selectedTab: Tab = Self.initialTab
    @Environment(\.scenePhase) private var scenePhase

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
                TodayView(client: client, syncEngine: syncEngine, appServices: appServices)
            }
            .tabItem { Label("Today", systemImage: "drop.fill") }
            .tag(Tab.today)

            NavigationStack {
                HistoryView(appServices: appServices)
            }
            .tabItem { Label("History", systemImage: "chart.bar.fill") }
            .tag(Tab.history)

            NavigationStack {
                SettingsView(client: client, appServices: appServices)
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            .tag(Tab.settings)
        }
        .tint(.hydraAccent)
        .environment(appServices.weatherService)
        .fullScreenCover(isPresented: onboardingBinding) {
            OnboardingFlow(client: client) {
                hasOnboarded = true
                Task { await appServices.requestPermissions() }
            }
        }
        .task {
            // Onboarding's own finish handler requests permissions for
            // first-time users; this covers every subsequent launch.
            #if DEBUG
            // Screenshot aid only: skips the system permission prompts so
            // an automated capture pass isn't blocked behind a dialog it
            // has no way to dismiss.
            let skipForScreenshot = ProcessInfo.processInfo.environment["HC_SKIP_PERMISSIONS"] == "1"
            #else
            let skipForScreenshot = false
            #endif
            if hasOnboarded && !skipForScreenshot {
                await appServices.requestPermissions()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Best-effort Focus re-check (V2-T4) — see AppServices.appDidBecomeActive.
            if newPhase == .active {
                appServices.appDidBecomeActive()
            }
        }
    }

    private var onboardingBinding: Binding<Bool> {
        Binding(get: { !hasOnboarded }, set: { hasOnboarded = !$0 })
    }
}
