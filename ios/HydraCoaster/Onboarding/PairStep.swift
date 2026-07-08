import SwiftUI

/// Step 2 of onboarding: pair with the coaster. Honest about every
/// Bluetooth state a fresh install can land in — the simulator always
/// reports `.unsupported`, so this must render sanely there, not spin, and
/// must stay walkable via the skip link.
struct PairStep: View {
    var client: CoasterClient
    var onContinue: () -> Void

    @State private var didAutoAdvance = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            statusGraphic

            VStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            if client.connectionState != .connected {
                Button("Set up later", action: onContinue)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 40)
        .onAppear { client.startScanning() }
        .onChange(of: client.managerState) { _, state in
            if state == .poweredOn { client.startScanning() }
        }
        .onChange(of: client.connectionState) { _, state in
            guard state == .connected, !didAutoAdvance else { return }
            didAutoAdvance = true
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                onContinue()
            }
        }
    }

    private var isBluetoothReady: Bool {
        client.managerState == .poweredOn || client.managerState == .unknown || client.managerState == .resetting
    }

    private var title: String {
        if client.connectionState == .connected { return "Coaster connected" }
        switch client.managerState {
        case .unsupported: return "Bluetooth unavailable"
        case .unauthorized: return "Bluetooth permission needed"
        case .poweredOff: return "Bluetooth is off"
        default: return "Looking for your coaster"
        }
    }

    private var message: String {
        if client.connectionState == .connected { return "HydraCoaster is ready to track your sips." }
        switch client.managerState {
        case .unsupported: return "This device can't scan for Bluetooth accessories. You can set up HydraCoaster and pair later."
        case .unauthorized: return "Allow Bluetooth access in Settings, then come back to pair."
        case .poweredOff: return "Turn on Bluetooth to find your coaster."
        default: return "Bring your coaster close — it connects automatically."
        }
    }

    private var statusGraphic: some View {
        ZStack {
            Circle()
                .fill(Color.hydraAccentSoft)
                .frame(width: 140, height: 140)

            if client.connectionState == .connected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(Color.hydraAccent)
            } else if isBluetoothReady {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.hydraAccent)
            } else {
                Image(systemName: unreadyIcon)
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(Color.hydraAccent)
            }
        }
        .frame(height: 260)
    }

    private var unreadyIcon: String {
        switch client.managerState {
        case .unauthorized: "hand.raised.fill"
        case .poweredOff: "power"
        default: "antenna.radiowaves.left.and.right.slash"
        }
    }
}
