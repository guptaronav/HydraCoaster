import SwiftUI

/// GitHub-style "Last 12 weeks" heatmap (V2-T5): one column per week,
/// oldest on the left, each column's 7 cells shaded by
/// `HeatmapCell.intensity` (0 = no data through 4 = >75% of goal). Tiny
/// weekday labels run down the left edge, read off the first (oldest, so
/// always fully populated) week's days.
struct HeatmapSection: View {
    /// Week-major grid from `Analytics.heatmapWeeks` — `nil` cells (days
    /// after "today") render as empty slots.
    let weeks: [[HeatmapCell?]]

    @Environment(\.hydraTheme) private var theme

    private let cellSize: CGFloat = 14
    private let cellSpacing: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Last 12 weeks")
                .font(.headline)
                .padding(.horizontal, 4)

            HStack(alignment: .top, spacing: 6) {
                weekdayLabels
                grid
            }
            .padding(20)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }

    private var weekdayLabels: some View {
        VStack(spacing: cellSpacing) {
            ForEach(0..<7, id: \.self) { row in
                Text(weekdayLabel(forRow: row))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: cellSize)
            }
        }
    }

    private func weekdayLabel(forRow row: Int) -> String {
        guard let firstWeek = weeks.first, row < firstWeek.count, let day = firstWeek[row]?.day else { return "" }
        return day.formatted(.dateTime.weekday(.narrow))
    }

    private var grid: some View {
        HStack(spacing: cellSpacing) {
            ForEach(weeks.indices, id: \.self) { weekIndex in
                VStack(spacing: cellSpacing) {
                    ForEach(0..<7, id: \.self) { row in
                        cell(weeks[weekIndex][row])
                    }
                }
            }
        }
    }

    private func cell(_ cell: HeatmapCell?) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(cell.map { theme.accent.opacity(opacity(forIntensity: $0.intensity)) } ?? Color.clear)
            .frame(width: cellSize, height: cellSize)
    }

    private func opacity(forIntensity intensity: Int) -> Double {
        switch intensity {
        case 0: return 0.08
        case 1: return 0.3
        case 2: return 0.5
        case 3: return 0.75
        default: return 1.0
        }
    }
}

#Preview {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let weeks = Analytics.heatmapWeeks(days: [], weekCount: 12, endingOn: today, calendar: calendar, goalML: 2000)
    return ScrollView {
        HeatmapSection(weeks: weeks)
            .padding(20)
    }
}
