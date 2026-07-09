import SwiftUI

/// Step 3 of onboarding: set the daily goal, then finish.
struct GoalStep: View {
    @Binding var goalML: Double
    @Binding var weightKg: Double?
    @Binding var heightCm: Double?
    @Binding var activityLevel: Int
    @Binding var usePersonalizedGoal: Bool
    var onFinish: () -> Void

    @Environment(\.hydraTheme) private var theme
    @State private var showPersonalize = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 12) {
                Text("Set your daily goal")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Pick a starting point — you can change this anytime in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            GoalPicker(
                goalML: $goalML,
                isPersonalized: $usePersonalizedGoal,
                onCalculateForMe: { showPersonalize = true }
            )
            .padding(.horizontal, 32)

            Spacer()

            Button("Start Tracking", action: onFinish)
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .controlSize(.large)
                .padding(.horizontal, 32)
        }
        .padding(.vertical, 40)
        .sheet(isPresented: $showPersonalize) {
            PersonalGoalEditor(
                weightKg: $weightKg,
                heightCm: $heightCm,
                activityLevel: $activityLevel,
                usePersonalizedGoal: $usePersonalizedGoal,
                goalML: $goalML
            )
        }
        #if DEBUG
        .task {
            // Screenshot aid only: `HC_SHOW_PERSONALIZE=1` opens the sheet
            // at launch so the gate can capture it without simulating a tap.
            if ProcessInfo.processInfo.environment["HC_SHOW_PERSONALIZE"] == "1" {
                showPersonalize = true
            }
        }
        #endif
    }
}

#Preview {
    GoalStep(
        goalML: .constant(2000),
        weightKg: .constant(nil),
        heightCm: .constant(nil),
        activityLevel: .constant(1),
        usePersonalizedGoal: .constant(false),
        onFinish: {}
    )
}
