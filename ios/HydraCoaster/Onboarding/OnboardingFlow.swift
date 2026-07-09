import SwiftData
import SwiftUI

/// First-launch flow: welcome, pair, set a goal. Three standalone step
/// views; this file only owns step order and the goal value step 3 writes
/// on finish.
struct OnboardingFlow: View {
    var client: CoasterClient
    var onFinished: () -> Void

    private enum Step: Int, CaseIterable {
        case welcome, pair, goal
    }

    @State private var step: Step = Self.initialStep
    @State private var goalML: Double = 2000
    @State private var weightKg: Double?
    @State private var heightCm: Double?
    @State private var activityLevel: Int = 1
    @State private var usePersonalizedGoal = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.hydraTheme) private var theme

    #if DEBUG
    /// Screenshot aid only: `HC_ONBOARDING_STEP=0|1|2` jumps straight to a
    /// step so the gate can capture each one without simulating taps.
    private static var initialStep: Step {
        guard let raw = ProcessInfo.processInfo.environment["HC_ONBOARDING_STEP"],
              let value = Int(raw), let step = Step(rawValue: value) else { return .welcome }
        return step
    }
    #else
    private static let initialStep: Step = .welcome
    #endif

    var body: some View {
        VStack(spacing: 0) {
            stepDots

            Group {
                switch step {
                case .welcome:
                    WelcomeStep { step = .pair }
                case .pair:
                    PairStep(client: client) { step = .goal }
                case .goal:
                    GoalStep(
                        goalML: $goalML,
                        weightKg: $weightKg,
                        heightCm: $heightCm,
                        activityLevel: $activityLevel,
                        usePersonalizedGoal: $usePersonalizedGoal
                    ) { finish() }
                }
            }
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.25), value: step)
        .background(Color(uiColor: .systemBackground))
    }

    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.self) { candidate in
                Capsule()
                    .fill(candidate.rawValue <= step.rawValue ? theme.accent : Color.primary.opacity(0.12))
                    .frame(width: candidate == step ? 20 : 8, height: 8)
            }
        }
        .padding(.top, 24)
    }

    private func finish() {
        let settings = AppSettings.fetchOrCreate(in: modelContext)
        settings.goalML = goalML
        settings.weightKg = weightKg
        settings.heightCm = heightCm
        settings.activityLevel = activityLevel
        settings.usePersonalizedGoal = usePersonalizedGoal
        try? modelContext.save()
        onFinished()
    }
}
