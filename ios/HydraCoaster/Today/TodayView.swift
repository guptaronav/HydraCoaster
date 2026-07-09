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

    private var goalML: Double {
        settings?.goalML ?? 2000
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                ConnectionHeader(connectionState: client.connectionState, batteryPercent: client.batteryPercent)

                GoalRingView(consumedML: consumedML, goalML: goalML)
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
