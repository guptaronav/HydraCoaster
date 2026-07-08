import SwiftUI

/// The hero: a thick rounded-cap progress ring with the day's consumption
/// centered inside. Progress caps visually at 100% — the number underneath
/// never lies about how much was actually drunk.
struct GoalRingView: View {
    let consumedML: Double
    let goalML: Double

    @ScaledMetric(relativeTo: .largeTitle) private var diameter: CGFloat = 232
    @ScaledMetric(relativeTo: .largeTitle) private var lineWidth: CGFloat = 20
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 52

    private var progress: Double {
        guard goalML > 0 else { return 0 }
        return min(consumedML / goalML, 1.0)
    }

    private var isOverGoal: Bool { goalML > 0 && consumedML > goalML }

    var body: some View {
        ZStack {
            // Accent-tinted track: keeps the hero alive at 0 ml and stays
            // visible against a dark background.
            Circle()
                .stroke(Color.hydraAccent.opacity(0.16), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.hydraAccent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: progress)

            VStack(spacing: 6) {
                Text(Int(consumedML.rounded()), format: .number)
                    .font(.system(size: numberSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: consumedML))

                Text("of \(Int(goalML)) ml")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if isOverGoal {
                    Text("goal reached")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.hydraAccent)
                        .padding(.top, 2)
                }
            }
            .animation(.easeOut(duration: 0.3), value: isOverGoal)
        }
        .frame(width: diameter, height: diameter)
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
