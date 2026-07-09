import Charts
import SwiftData
import SwiftUI

/// Last 14 days of intake: bar chart with a goal line, plus the sips for
/// whichever day is selected (today by default). Pure bucketing math lives
/// in DailyTotals so it's testable without SwiftData in the loop.
struct HistoryView: View {
    var appServices: AppServices

    @Query private var allSips: [SipEvent]
    @Environment(\.modelContext) private var modelContext
    @State private var settings: AppSettings?
    @State private var selectedDay: Date?

    private var goalML: Double { settings?.goalML ?? 2000 }

    private var totals: [DailyTotal] {
        let records = allSips.map {
            SipRecord(
                seq: $0.seq, date: $0.date, grams: $0.grams, isEstimatedDate: $0.isEstimatedDate,
                typeID: $0.typeID, hydrationFactor: $0.hydrationFactor, isManual: $0.isManual,
                hkSampleUUID: $0.hkSampleUUID
            )
        }
        return DailyTotals.compute(from: records)
    }

    private var displayedDay: Date {
        Calendar.current.startOfDay(for: selectedDay ?? Date())
    }

    private var sipsForDisplayedDay: [SipEvent] {
        allSips
            .filter { Calendar.current.isDate($0.date, inSameDayAs: displayedDay) }
            .sorted { $0.date > $1.date }
    }

    private var sectionTitle: String {
        Calendar.current.isDateInToday(displayedDay) ? "Today's sips" : "\(dayLabel) sips"
    }

    private var dayLabel: String {
        displayedDay.formatted(.dateTime.month(.abbreviated).day())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                chart
                SipListSection(
                    sips: sipsForDisplayedDay,
                    title: sectionTitle,
                    emptyText: "No sips on this day.",
                    onReclassify: { sip, drink in appServices.reclassify(seq: sip.seq, to: drink) }
                )
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("History")
        .task {
            settings = AppSettings.fetchOrCreate(in: modelContext)
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Last 14 days")
                .font(.headline)

            Chart {
                ForEach(totals, id: \.day) { entry in
                    BarMark(
                        x: .value("Day", entry.day, unit: .day),
                        y: .value("ml", entry.totalML)
                    )
                    .foregroundStyle(
                        Calendar.current.isDate(entry.day, inSameDayAs: displayedDay)
                            ? Color.hydraAccent
                            : Color.hydraAccent.opacity(0.35)
                    )
                }

                RuleMark(y: .value("Goal", goalML))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .foregroundStyle(.secondary)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let ml = value.as(Double.self) {
                            Text(Int(ml), format: .number)
                        }
                    }
                }
            }
            .chartXSelection(value: $selectedDay)
            .frame(height: 220)
        }
        .padding(20)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

#Preview {
    let container = try! ModelContainer.ephemeral()
    let store = SwiftDataSipStore(modelContext: container.mainContext)
    let services = AppServices(client: CoasterClient(), syncEngine: SyncEngine(store: store), store: store)
    NavigationStack { HistoryView(appServices: services) }
        .modelContainer(container)
}
