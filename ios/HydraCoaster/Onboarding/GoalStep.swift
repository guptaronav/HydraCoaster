import SwiftUI

/// Step 3 of onboarding: set the daily goal, then finish.
struct GoalStep: View {
    @Binding var goalML: Double
    var onFinish: () -> Void

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

            GoalPicker(goalML: $goalML)
                .padding(.horizontal, 32)

            Spacer()

            Button("Start Tracking", action: onFinish)
                .buttonStyle(.borderedProminent)
                .tint(.hydraAccent)
                .controlSize(.large)
                .padding(.horizontal, 32)
        }
        .padding(.vertical, 40)
    }
}

#Preview {
    GoalStep(goalML: .constant(2000), onFinish: {})
}
