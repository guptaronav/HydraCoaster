import SwiftUI

/// Today toolbar's "+" — manual sip entry. Amount + drink type + time, then
/// `SyncEngine.logManualSip` — the SAME store/dedupe/fan-out path coaster
/// sips go through, so HealthKit logging and reminder rescheduling happen
/// exactly once, in exactly one place (SyncEngine.persist).
struct LogDrinkSheet: View {
    var syncEngine: SyncEngine

    @Environment(\.dismiss) private var dismiss
    @Environment(\.hydraTheme) private var theme
    @State private var amountML: Double = 350
    @State private var selectedDrink: DrinkType = DrinkCatalog.water
    @State private var date = Date()
    @State private var searchText = ""

    private static let presets: [Double] = [250, 350, 500]

    var body: some View {
        NavigationStack {
            Form {
                if searchText.isEmpty {
                    amountSection
                }

                DrinkTypeGrid(selection: $selectedDrink, searchText: searchText)

                if searchText.isEmpty {
                    Section("Time") {
                        DatePicker("Time", selection: $date, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.compact)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search drinks")
            .navigationTitle("Log a Drink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log") {
                        syncEngine.logManualSip(drink: selectedDrink, grams: amountML, date: date)
                        dismiss()
                    }
                    .disabled(amountML <= 0)
                }
            }
        }
    }

    private var amountSection: some View {
        Section("Amount") {
            HStack(spacing: 10) {
                ForEach(Self.presets, id: \.self) { preset in
                    chip(for: preset)
                }
            }

            HStack {
                TextField("Amount", text: amountText)
                    .keyboardType(.numberPad)
                Text("ml").foregroundStyle(.secondary)
            }
        }
    }

    private func chip(for preset: Double) -> some View {
        let isSelected = amountML == preset
        return Button {
            amountML = preset
        } label: {
            Text(Int(preset), format: .number)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? theme.accent : Color.primary.opacity(0.06), in: Capsule())
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private var amountText: Binding<String> {
        Binding(
            get: { amountML > 0 ? String(Int(amountML.rounded())) : "" },
            set: { newValue in amountML = Double(newValue) ?? 0 }
        )
    }
}

#Preview {
    LogDrinkSheet(syncEngine: SyncEngine(store: PreviewSipStore()))
}

/// No-op store so the sheet previews without wiring the real SwiftData/BLE
/// stack — nothing in this preview persists a sip.
private final class PreviewSipStore: SipEventStoring {
    func loadAll() -> [SipRecord] { [] }
    func insert(_ record: SipRecord) {}
    func deleteAll() {}
    func record(seq: Int) -> SipRecord? { nil }
    func updateType(seq: Int, typeID: String, hydrationFactor: Double) {}
    func updateHealthKitUUID(seq: Int, uuid: String?) {}
}
