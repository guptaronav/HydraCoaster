import SwiftData
import SwiftUI

/// 4th tab (V2-T3): today's score, streaks, and the badge catalog. All the
/// math lives in `Awards`/`AppServices.awardsSnapshot` — this view only lays
/// it out.
struct AwardsView: View {
    var appServices: AppServices

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
    }

    private func header(_ snapshot: AwardsSnapshot) -> some View {
        HStack(spacing: 12) {
            statTile(icon: "flame.fill", value: snapshot.currentStreak, label: "day streak")
            statTile(icon: "drop.fill", value: snapshot.dailyScore, label: "today's score")
            statTile(icon: "trophy.fill", value: snapshot.longestStreak, label: "longest streak")
        }
    }

    private func statTile(icon: String, value: Int, label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(Color.hydraAccent)
            Text(value, format: .number)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
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
                ForEach(Awards.catalog) { badge in
                    badgeTile(badge, earnedDate: snapshot.badges[badge.id])
                }
            }
        }
    }

    private func badgeTile(_ badge: Badge, earnedDate: Date?) -> some View {
        let isEarned = earnedDate != nil
        return VStack(spacing: 8) {
            Image(systemName: badge.symbol)
                .font(.title2)
                .foregroundStyle(isEarned ? Color.hydraAccent : .secondary)
                .opacity(isEarned ? 1 : 0.4)

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
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(isEarned ? 1 : 0.6)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    let container = try! ModelContainer.ephemeral()
    let store = SwiftDataSipStore(modelContext: container.mainContext)
    let services = AppServices(client: CoasterClient(), syncEngine: SyncEngine(store: store), store: store)
    NavigationStack { AwardsView(appServices: services) }
        .modelContainer(container)
}
