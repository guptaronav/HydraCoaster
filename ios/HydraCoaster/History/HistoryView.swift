import Charts
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Week/month range chart with a goal line, the per-drink breakdown, a
/// 12-week heatmap, and CSV export (V2-T5), plus the sips for whichever day
/// is selected on the chart (today by default). All the range/breakdown/
/// heatmap math lives in Analytics, sourced from `AppServices.
/// historySnapshot` rather than a local SwiftData query, so it's testable
/// without SwiftData in the loop and never drifts from Awards' idea of a
/// day's total.
struct HistoryView: View {
    var appServices: AppServices

    @Query private var allSips: [SipEvent]
    @Environment(\.modelContext) private var modelContext
    @State private var settings: AppSettings?
    @State private var selectedDay: Date?
    @State private var range: HistoryRange = .week

    private var goalML: Double { settings?.goalML ?? 2000 }

    private var snapshot: HistorySnapshot { appServices.historySnapshot }

    private var totals: [DailyTotal] {
        Analytics.rangeTotals(days: snapshot.dailyTotals, range: range, endingOn: Date(), calendar: .current)
    }

    private var typeSlices: [TypeSlice] {
        Analytics.typeBreakdown(sips: snapshot.sips, range: range, endingOn: Date(), calendar: .current)
    }

    private var heatmapWeeks: [[HeatmapCell?]] {
        Analytics.heatmapWeeks(days: snapshot.dailyTotals, endingOn: Date(), calendar: .current, goalML: goalML)
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
                rangePicker
                chart
                TypeBreakdownSection(slices: typeSlices)
                HeatmapSection(weeks: heatmapWeeks)
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(
                    item: CSVExport(makeCSV: { Analytics.csv(sips: snapshot.sips) }),
                    preview: SharePreview("HydraCoaster-sips.csv")
                ) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
        }
        .task {
            settings = AppSettings.fetchOrCreate(in: modelContext)
        }
    }

    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            ForEach(HistoryRange.allCases, id: \.self) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(range == .week ? "Last 7 days" : "Last 30 days")
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
                AxisMarks(values: .stride(by: range == .week ? .day : .weekOfYear)) { _ in
                    AxisValueLabel(format: range == .week ? .dateTime.weekday(.narrow) : .dateTime.month(.abbreviated).day())
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

/// Lazy CSV payload for the toolbar ShareLink: the string (and its bytes)
/// only materialize when the user actually shares, keeping `Analytics.csv`
/// out of HistoryView's render path — no temp files, no I/O per body
/// evaluation.
struct CSVExport: Transferable {
    let makeCSV: () -> String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { export in
            Data(export.makeCSV().utf8)
        }
        .suggestedFileName("HydraCoaster-sips.csv")
    }
}

#Preview {
    let container = try! ModelContainer.ephemeral()
    let store = SwiftDataSipStore(modelContext: container.mainContext)
    let services = AppServices(client: CoasterClient(), syncEngine: SyncEngine(store: store), store: store)
    NavigationStack { HistoryView(appServices: services) }
        .modelContainer(container)
}
