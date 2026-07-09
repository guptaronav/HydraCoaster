import SwiftData
import SwiftUI

/// The app's main screen (T5 adds tabs around it — this stays a self-
/// contained screen so that's a drop-in change).
struct TodayView: View {
    var client: CoasterClient
    var syncEngine: SyncEngine
    var appServices: AppServices

    @Query(sort: \SipEvent.date, order: .reverse) private var allSips: [SipEvent]
    @Environment(\.modelContext) private var modelContext
    @Environment(WeatherService.self) private var weather
    @Environment(\.hydraTheme) private var theme
    @State private var settings: AppSettings?
    @State private var showingLogSheet = false

    // ponytail: today-filter duplicates SyncEngine.consumedToday()'s date
    // logic in ~1 line; sharing it would mean plumbing a FetchDescriptor
    // predicate through both @Query (compile-time) and the engine's ad-hoc
    // fetch, which costs more than it saves at this size.
    private var todaysSips: [SipEvent] {
        allSips.filter { Calendar.current.isDateInToday($0.date) }
    }

    private var consumedML: Double {
        todaysSips.reduce(0) { $0 + $1.effectiveGrams }
    }

    private var baseGoalML: Double {
        settings?.goalML ?? 2000
    }

    /// Weather scales the goal up (V2-T1) — the ring shows this; History's
    /// goal line stays at `baseGoalML` for day-to-day comparability.
    private var effectiveGoalML: Double {
        GoalCalculator.effectiveGoalML(base: baseGoalML, reminderFactor: weather.lastFactor)
    }

    private var weatherFactor: Double {
        GoalCalculator.weatherGoalFactor(reminderFactor: weather.lastFactor)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                ConnectionHeader(connectionState: client.connectionState, batteryPercent: client.batteryPercent)

                VStack(spacing: 4) {
                    GoalRingView(consumedML: consumedML, goalML: effectiveGoalML)

                    if weatherFactor > 1 {
                        Text("+\(Int(((weatherFactor - 1) * 100).rounded()))% weather")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.accent)
                    }

                    // Subtle nudge only once there's something to show off
                    // (V2-T3) — a 1-day "streak" isn't a streak yet.
                    let currentStreak = appServices.awardsSnapshot.currentStreak
                    if currentStreak >= 2 {
                        streakChip(days: currentStreak)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                LiveReadingCard(
                    connectionState: client.connectionState,
                    weight: client.latestWeight,
                    onScanTapped: { client.startScanning() }
                )

                SipListSection(sips: todaysSips, onReclassify: reclassify)
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Today")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingLogSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
            #if DEBUG
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink("Debug") {
                    ConnectionDebugView(client: client, syncEngine: syncEngine, appServices: appServices)
                }
                .font(.caption)
            }
            #endif
        }
        .sheet(isPresented: $showingLogSheet) {
            LogDrinkSheet(syncEngine: syncEngine)
        }
        .task {
            syncEngine.start(with: client)
            settings = AppSettings.fetchOrCreate(in: modelContext)
            #if DEBUG
            // Screenshot aid only: `HC_SHOW_LOG_SHEET=1` opens the Quick Log
            // sheet at launch so the gate can capture it without simulating a tap.
            if ProcessInfo.processInfo.environment["HC_SHOW_LOG_SHEET"] == "1" {
                showingLogSheet = true
            }
            #endif
        }
    }

    private func reclassify(_ sip: SipEvent, to drink: DrinkType) {
        appServices.reclassify(seq: sip.seq, to: drink)
    }

    private func streakChip(days: Int) -> some View {
        Label("\(days) day streak", systemImage: "flame.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(theme.accent.opacity(0.12), in: Capsule())
            .padding(.top, 2)
    }
}
