import SwiftData
import SwiftUI

/// 4th tab (V2-T3): today's score, streaks, and the badge catalog. All the
/// math lives in `Awards`/`AppServices.awardsSnapshot` — this view only lays
/// it out.
struct AwardsView: View {
    var appServices: AppServices

    @Environment(\.hydraTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the one-time staggered entrance of the badge grid.
    @State private var hasAppeared = false

    private static let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        let snapshot = appServices.awardsSnapshot

        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header(snapshot)
                badgeGrid(snapshot)
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Awards")
        .onAppear { hasAppeared = true }
    }

    private func header(_ snapshot: AwardsSnapshot) -> some View {
        HStack(spacing: 12) {
            statTile(icon: "flame.fill", value: snapshot.currentStreak, label: "day streak")
            statTile(icon: "drop.fill", value: snapshot.dailyScore, label: "today's score")
            statTile(icon: "trophy.fill", value: snapshot.longestStreak, label: "longest streak")
        }
    }

    private func statTile(icon: String, value: Int, label: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(theme.accent)
                .symbolEffect(.bounce, value: value) // nudge when the number moves
                .frame(width: 34, height: 34)
                .background(
                    theme.accent.opacity(0.14),
                    in: Circle()
                )
            Text(value, format: .number)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
                .animation(.snappy(duration: 0.4), value: value)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func badgeGrid(_ snapshot: AwardsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Badges")
                .font(.headline)
                .padding(.horizontal, 4)

            LazyVGrid(columns: Self.columns, spacing: 12) {
                ForEach(Array(Awards.catalog.enumerated()), id: \.element.id) { index, badge in
                    badgeTile(badge, earnedDate: snapshot.badges[badge.id])
                        .opacity(hasAppeared ? 1 : 0)
                        .scaleEffect(hasAppeared ? 1 : 0.85)
                        // Cascading spring on first appear; nil under Reduce
                        // Motion so the tiles simply snap visible.
                        .animation(
                            reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.75)
                                .delay(Double(index) * 0.04),
                            value: hasAppeared
                        )
                }
            }
        }
    }

    private func badgeTile(_ badge: Badge, earnedDate: Date?) -> some View {
        let isEarned = earnedDate != nil
        return VStack(spacing: 8) {
            Image(systemName: badge.symbol)
                .font(.title2)
                .foregroundStyle(isEarned ? theme.accent : .secondary)
                .opacity(isEarned ? 1 : 0.4)
                .symbolEffect(.bounce, value: isEarned) // pops the moment it's earned

            Text(badge.name)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(isEarned ? .primary : .secondary)

            Text(isEarned ? earnedDate!.formatted(.dateTime.month(.abbreviated).day()) : badge.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 108)
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .background(badgeBackground(isEarned: isEarned))
        .opacity(isEarned ? 1 : 0.6)
        .accessibilityElement(children: .combine)
    }

    /// Earned badges sit on an accent-washed card with a hairline accent
    /// border so they read as trophies; locked ones stay quiet material.
    @ViewBuilder
    private func badgeBackground(isEarned: Bool) -> some View {
        if isEarned {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.accent.opacity(0.22), theme.accent.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(theme.accent.opacity(0.35), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.thickMaterial)
        }
    }
}

#Preview {
    let container = try! ModelContainer.ephemeral()
    let store = SwiftDataSipStore(modelContext: container.mainContext)
    let services = AppServices(client: CoasterClient(), syncEngine: SyncEngine(store: store), store: store)
    NavigationStack { AwardsView(appServices: services) }
        .modelContainer(container)
}
