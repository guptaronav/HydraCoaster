import SwiftUI

/// Step 1 of onboarding: what the app is, in one breath.
struct WelcomeStep: View {
    var onContinue: () -> Void

    @Environment(\.hydraTheme) private var theme

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            heroGraphic

            VStack(spacing: 12) {
                Text("HydraCoaster")
                    .font(.system(size: 34, weight: .bold, design: .rounded))

                Text("Your coaster weighs every sip, so your daily water goal fills itself in.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            Button("Get Started", action: onContinue)
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .controlSize(.large)
                .padding(.horizontal, 32)
        }
        .padding(.vertical, 40)
    }

    private var heroGraphic: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { ring in
                Circle()
                    .stroke(theme.accent.opacity(0.14 - Double(ring) * 0.03), lineWidth: 1)
                    .frame(width: 160 + CGFloat(ring) * 50, height: 160 + CGFloat(ring) * 50)
            }

            Circle()
                .fill(Color.hydraAccentSoft)
                .frame(width: 140, height: 140)

            Image(systemName: "drop.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(theme.accent)
        }
        .frame(height: 260)
    }
}

#Preview {
    WelcomeStep(onContinue: {})
}
