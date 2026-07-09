import SwiftUI
import WidgetKit

/// One timeline entry wrapping the app's last-written `WidgetState`. A
/// separate wrapper (rather than making `WidgetState` itself conform to
/// `TimelineEntry`) keeps `WidgetState` WidgetKit-free — it's shared with
/// the app target, which has no reason to import WidgetKit.
struct HydraEntry: TimelineEntry {
    let date: Date
    let state: WidgetState
}

/// Reads the App Group snapshot `AppServices` writes and hands back a
/// single entry — there's nothing to compute ahead of time (unlike a
/// forecast widget), so one entry refreshed on a timer is all a "today's
/// progress" widget needs.
struct HydraProvider: TimelineProvider {
    /// Demo values for the widget gallery / first render before the app has
    /// ever written a snapshot.
    private static let placeholderState = WidgetState(
        consumedML: 1200,
        goalML: 2000,
        streak: 3,
        themeRaw: Theme.aqua.rawValue,
        updatedAt: Date()
    )
    private static let refreshInterval: TimeInterval = 30 * 60

    func placeholder(in context: Context) -> HydraEntry {
        HydraEntry(date: Date(), state: Self.placeholderState)
    }

    func getSnapshot(in context: Context, completion: @escaping (HydraEntry) -> Void) {
        completion(HydraEntry(date: Date(), state: WidgetStateStore.load() ?? Self.placeholderState))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HydraEntry>) -> Void) {
        let entry = HydraEntry(date: Date(), state: WidgetStateStore.load() ?? Self.placeholderState)
        let nextRefresh = Date().addingTimeInterval(Self.refreshInterval)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct HydraWidget: Widget {
    private let kind = "HydraWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HydraProvider()) { entry in
            HydraWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
        }
        .configurationDisplayName("Hydration")
        .description("Today's water progress and streak.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct HydraWidgetView: View {
    let entry: HydraEntry

    @Environment(\.widgetFamily) private var family

    private var theme: Theme { Theme(rawValue: entry.state.themeRaw) ?? .aqua }

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        default:
            small
        }
    }

    private var small: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(theme.accent.opacity(0.16), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: entry.state.progress)
                    .stroke(theme.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(amountLabel)
                    .font(.system(.callout, design: .rounded, weight: .bold))
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 6)
            }
            .padding(6)

            if entry.state.streak >= 2 {
                Label("\(entry.state.streak)", systemImage: "flame.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.accent)
            }
        }
        .padding(8)
    }

    private var circular: some View {
        Gauge(value: entry.state.progress) {
            Image(systemName: "drop.fill")
        } currentValueLabel: {
            Text(entry.state.progress, format: .percent.precision(.fractionLength(0)))
        }
        .gaugeStyle(.accessoryCircular)
        .tint(theme.accent)
    }

    /// "1.2 L / 2 L" style label — whole liters render without a decimal,
    /// fractional ones round to one place.
    private var amountLabel: String {
        "\(formattedLiters(entry.state.consumedML)) / \(formattedLiters(entry.state.goalML))"
    }

    private func formattedLiters(_ ml: Double) -> String {
        let liters = ml / 1000
        if liters.rounded() == liters {
            return "\(Int(liters)) L"
        }
        return String(format: "%.1f L", liters)
    }
}

#Preview(as: .systemSmall) {
    HydraWidget()
} timeline: {
    HydraEntry(date: .now, state: WidgetState(consumedML: 1200, goalML: 2000, streak: 3, themeRaw: 0, updatedAt: .now))
}

#Preview(as: .accessoryCircular) {
    HydraWidget()
} timeline: {
    HydraEntry(date: .now, state: WidgetState(consumedML: 1200, goalML: 2000, streak: 3, themeRaw: 0, updatedAt: .now))
}
