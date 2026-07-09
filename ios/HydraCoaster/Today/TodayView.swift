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
    @State private var settings: AppSettings?

    // ponytail: today-filter duplicates SyncEngine.consumedToday()'s date
    // logic in ~1 line; sharing it would mean plumbing a FetchDescriptor
    // predicate through both @Query (compile-time) and the engine's ad-hoc
    // fetch, which costs more than it saves at this size.
    private var todaysSips: [SipEvent] {
        allSips.filter { Calendar.current.isDateInToday($0.date) }
    }

    private var consumedML: Double {
        todaysSips.reduce(0) { $0 + $1.grams }
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
                            .foregroundStyle(Color.hydraAccent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                LiveReadingCard(
                    connectionState: client.connectionState,
                    weight: client.latestWeight,
                    onScanTapped: { client.startScanning() }
                )

                SipListSection(sips: todaysSips)
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Today")
        .toolbar {
            #if DEBUG
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink("Debug") {
                    ConnectionDebugView(client: client, syncEngine: syncEngine, appServices: appServices)
                }
                .font(.caption)
            }
            #endif
        }
        .task {
            syncEngine.start(with: client)
            settings = AppSettings.fetchOrCreate(in: modelContext)
        }
    }
}
