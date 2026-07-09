import SwiftUI

/// Sheet for V2-T1's opt-in personalized goal: weight/height/activity in,
/// live formula preview out. Presented from `GoalPicker`'s "Calculate for
/// me" affordance in both onboarding and Settings. Stores metric only —
/// the lb/kg and cm/ft-in toggles here are display-only conversions.
struct PersonalGoalEditor: View {
    @Binding var weightKg: Double?
    @Binding var heightCm: Double?
    @Binding var activityLevel: Int
    @Binding var usePersonalizedGoal: Bool
    @Binding var goalML: Double

    @Environment(\.dismiss) private var dismiss
    @Environment(\.hydraTheme) private var theme
    @State private var weightUnit: WeightUnit = .kg
    @State private var heightUnit: HeightUnit = .cm

    private enum WeightUnit: String, CaseIterable { case kg, lb }
    private enum HeightUnit: String, CaseIterable { case cm, ftIn = "ft/in" }

    private static let kgPerLb = 0.45359237
    private static let cmPerInch = 2.54

    private var computedGoalML: Double? {
        guard let weightKg, let heightCm, weightKg > 0, heightCm > 0 else { return nil }
        return GoalCalculator.baseGoalML(weightKg: weightKg, heightCm: heightCm, activityLevel: activityLevel)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Weight") {
                    Picker("Weight unit", selection: $weightUnit) {
                        ForEach(WeightUnit.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    HStack {
                        TextField("Weight", text: weightText)
                            .keyboardType(.decimalPad)
                        Text(weightUnit.rawValue).foregroundStyle(.secondary)
                    }
                }

                Section("Height") {
                    Picker("Height unit", selection: $heightUnit) {
                        ForEach(HeightUnit.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if heightUnit == .cm {
                        HStack {
                            TextField("Height", text: heightCmText)
                                .keyboardType(.decimalPad)
                            Text("cm").foregroundStyle(.secondary)
                        }
                    } else {
                        HStack {
                            TextField("ft", text: feetText).keyboardType(.numberPad)
                            Text("ft").foregroundStyle(.secondary)
                            TextField("in", text: inchesText).keyboardType(.numberPad)
                            Text("in").foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Activity level") {
                    Picker("Activity level", selection: $activityLevel) {
                        Text("Sedentary").tag(0)
                        Text("Moderate").tag(1)
                        Text("Active").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section {
                    preview
                    Toggle("Use personalized goal", isOn: $usePersonalizedGoal)
                        .disabled(computedGoalML == nil)
                } footer: {
                    Text("Weight × 30 ml, plus 5 ml per cm over 160, plus an activity bonus — rounded to the nearest 50 ml.")
                }
            }
            .navigationTitle("Personalize Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: computedGoalML) { _, _ in syncGoalIfPersonalized() }
            .onChange(of: usePersonalizedGoal) { _, _ in syncGoalIfPersonalized() }
        }
    }

    private func syncGoalIfPersonalized() {
        guard usePersonalizedGoal, let computedGoalML else { return }
        goalML = computedGoalML
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Personalized goal")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let computedGoalML {
                (
                    Text(Int(computedGoalML), format: .number)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.accent)
                    + Text(" ml")
                        .font(.headline.weight(.medium))
                        .foregroundStyle(.secondary)
                )
                .monospacedDigit()
                .contentTransition(.numericText(value: computedGoalML))
            } else {
                Text("Enter weight and height")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .animation(.easeOut(duration: 0.2), value: computedGoalML)
    }

    private var weightText: Binding<String> {
        Binding(
            get: {
                guard let weightKg else { return "" }
                let display = weightUnit == .kg ? weightKg : weightKg / Self.kgPerLb
                return String(format: "%.0f", display)
            },
            set: { newValue in
                guard let entered = Double(newValue), entered > 0 else {
                    weightKg = nil
                    return
                }
                weightKg = weightUnit == .kg ? entered : entered * Self.kgPerLb
            }
        )
    }

    private var heightCmText: Binding<String> {
        Binding(
            get: { heightCm.map { String(format: "%.0f", $0) } ?? "" },
            set: { newValue in
                guard let entered = Double(newValue), entered > 0 else {
                    heightCm = nil
                    return
                }
                heightCm = entered
            }
        )
    }

    /// Whole feet/inches derived from `heightCm` — imperial fields are two
    /// small components of the one stored metric value, not their own state.
    private var feetInches: (feet: Int, inches: Int) {
        guard let heightCm, heightCm > 0 else { return (0, 0) }
        let totalInches = Int((heightCm / Self.cmPerInch).rounded())
        return (totalInches / 12, totalInches % 12)
    }

    private var feetText: Binding<String> {
        Binding(
            get: { heightCm == nil ? "" : String(feetInches.feet) },
            set: { newValue in setHeightFromImperial(feet: Int(newValue) ?? 0, inches: feetInches.inches) }
        )
    }

    private var inchesText: Binding<String> {
        Binding(
            get: { heightCm == nil ? "" : String(feetInches.inches) },
            set: { newValue in setHeightFromImperial(feet: feetInches.feet, inches: Int(newValue) ?? 0) }
        )
    }

    private func setHeightFromImperial(feet: Int, inches: Int) {
        guard feet > 0 || inches > 0 else {
            heightCm = nil
            return
        }
        heightCm = Double(feet * 12 + inches) * Self.cmPerInch
    }
}

#Preview {
    PersonalGoalEditor(
        weightKg: .constant(70),
        heightCm: .constant(175),
        activityLevel: .constant(1),
        usePersonalizedGoal: .constant(true),
        goalML: .constant(2500)
    )
}
