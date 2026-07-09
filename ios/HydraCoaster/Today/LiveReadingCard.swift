import SwiftUI

/// Secondary card: what's on the coaster right now. Honest about having
/// nothing to show — no fake data, no signal-strength cosplay.
struct LiveReadingCard: View {
    let connectionState: ConnectionState
    let weight: WeightReading?
    let onScanTapped: () -> Void

    @Environment(\.hydraTheme) private var theme

    var body: some View {
        Group {
            if connectionState == .connected, let weight {
                connectedContent(weight)
            } else {
                disconnectedContent
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func connectedContent(_ weight: WeightReading) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ON THE COASTER")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.2)

            (
                Text(weight.grams, format: .number.precision(.fractionLength(1)))
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                + Text(" g")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            )
            .monospacedDigit()

            HStack(spacing: 8) {
                StatusChip(label: weight.settled ? "Settled" : "Settling", isActive: weight.settled)
                StatusChip(label: weight.cupPresent ? "Cup present" : "No cup", isActive: weight.cupPresent)
            }
        }
    }

    private var disconnectedContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Coaster not connected")
                .font(.system(size: 18, weight: .semibold, design: .rounded))

            Text("Bring it nearby and scan to reconnect.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button(action: onScanTapped) {
                Label(
                    connectionState == .scanning || connectionState == .connecting ? "Scanning…" : "Scan for coaster",
                    systemImage: "dot.radiowaves.left.and.right"
                )
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
            .disabled(connectionState == .scanning || connectionState == .connecting)
        }
    }
}

private struct StatusChip: View {
    let label: String
    let isActive: Bool

    @Environment(\.hydraTheme) private var theme

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isActive ? theme.accent.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
            .foregroundStyle(isActive ? theme.accent : .secondary)
    }
}

#Preview {
    VStack(spacing: 20) {
        LiveReadingCard(
            connectionState: .connected,
            weight: WeightReading(grams: 214.6, settled: true, cupPresent: true, clockSynced: true, stddev: 0.3),
            onScanTapped: {}
        )
        LiveReadingCard(connectionState: .disconnected, weight: nil, onScanTapped: {})
    }
    .padding()
}
