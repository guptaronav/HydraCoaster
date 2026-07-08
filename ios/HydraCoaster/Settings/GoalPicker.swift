import SwiftUI

/// Daily-goal editor: current value, preset chips, fine adjust. Shared by
/// onboarding's goal step and the Settings goal section so both read as the
/// same control.
struct GoalPicker: View {
    @Binding var goalML: Double

    private static let presets: [Double] = [1500, 2000, 2500, 3000]
    private static let fineStep: Double = 50
    private static let floorML: Double = 200

    var body: some View {
        VStack(spacing: 20) {
            (
                Text(Int(goalML), format: .number)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                + Text(" ml")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            )
            .monospacedDigit()
            .contentTransition(.numericText(value: goalML))

            HStack(spacing: 10) {
                ForEach(Self.presets, id: \.self) { preset in
                    chip(for: preset)
                }
            }

            HStack(spacing: 20) {
                Button {
                    goalML = max(Self.floorML, goalML - Self.fineStep)
                } label: {
                    Image(systemName: "minus.circle.fill").font(.title2)
                }

                Text("adjust by \(Int(Self.fineStep)) ml")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    goalML += Self.fineStep
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
            }
            .foregroundStyle(Color.hydraAccent)
            .buttonStyle(.plain)
        }
        .animation(.easeOut(duration: 0.2), value: goalML)
    }

    private func chip(for preset: Double) -> some View {
        let isSelected = goalML == preset
        return Button {
            goalML = preset
        } label: {
            Text(Int(preset), format: .number)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? Color.hydraAccent : Color.primary.opacity(0.06), in: Capsule())
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    GoalPicker(goalML: .constant(2000))
        .padding()
}
