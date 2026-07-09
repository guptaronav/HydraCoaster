import SwiftUI

/// Header row: a status dot + name, and battery percent once it's known.
struct ConnectionHeader: View {
    let connectionState: ConnectionState
    let batteryPercent: Int?

    @Environment(\.hydraTheme) private var theme

    private var statusColor: Color {
        switch connectionState {
        case .connected: theme.accent
        case .connecting, .scanning: .yellow
        case .disconnected: .secondary
        }
    }

    private var statusLabel: String {
        switch connectionState {
        case .connected: "HydraCoaster"
        case .connecting: "Connecting…"
        case .scanning: "Scanning…"
        case .disconnected: "Not connected"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)

            Text(statusLabel)
                .font(.subheadline.weight(.semibold))

            Spacer()

            if let batteryPercent {
                Label("\(batteryPercent)%", systemImage: batteryIcon(for: batteryPercent))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func batteryIcon(for percent: Int) -> String {
        switch percent {
        case ..<20: "battery.25"
        case ..<50: "battery.50"
        case ..<80: "battery.75"
        default: "battery.100"
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        ConnectionHeader(connectionState: .connected, batteryPercent: 82)
        ConnectionHeader(connectionState: .disconnected, batteryPercent: nil)
    }
    .padding()
}
