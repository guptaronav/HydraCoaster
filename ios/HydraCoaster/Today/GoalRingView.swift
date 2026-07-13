import SwiftUI

/// The hero: a thick rounded-cap progress ring with the day's consumption
/// centered inside. Progress caps visually at 100% — the number underneath
/// never lies about how much was actually drunk.
struct GoalRingView: View {
    let consumedML: Double
    let goalML: Double

    @Environment(\.hydraTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var diameter: CGFloat = 232
    @ScaledMetric(relativeTo: .largeTitle) private var lineWidth: CGFloat = 20
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 52
    /// One-shot scale pulse the moment the ring first fills (V3 polish) —
    /// the on-phone echo of the coaster's celebration flourish.
    @State private var goalPulse = false

    private var progress: Double {
        guard goalML > 0 else { return 0 }
        return min(consumedML / goalML, 1.0)
    }

    private var isOverGoal: Bool { goalML > 0 && consumedML >= goalML }

    /// First and last stops match so the ends meet seamlessly at 100%; the
    /// lighter mid-sweep gives the arc a liquid sheen instead of flat ink.
    private var ringGradient: AngularGradient {
        AngularGradient(
            colors: [theme.accent, theme.accent.opacity(0.65), theme.accent],
            center: .center
        )
    }

    var body: some View {
        ZStack {
            // Accent-tinted track: keeps the hero alive at 0 ml and stays
            // visible against a dark background.
            Circle()
                .stroke(theme.accent.opacity(0.16), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(ringGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.7, dampingFraction: 0.8), value: progress)

            VStack(spacing: 6) {
                Text(Int(consumedML.rounded()), format: .number)
                    .font(.system(size: numberSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: consumedML))
                    .animation(.snappy(duration: 0.4), value: consumedML)

                Text("of \(Int(goalML)) ml")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if isOverGoal {
                    Label("goal reached", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.accent)
                        .padding(.top, 2)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isOverGoal)
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(goalPulse ? 1.05 : 1)
        .onChange(of: isOverGoal) { _, reached in
            guard reached, !reduceMotion else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { goalPulse = true }
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { goalPulse = false }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today's water")
        .accessibilityValue("\(Int(consumedML)) of \(Int(goalML)) milliliters")
    }
}

#Preview {
    VStack(spacing: 40) {
        GoalRingView(consumedML: 750, goalML: 2000)
        GoalRingView(consumedML: 2400, goalML: 2000)
    }
    .padding()
}
