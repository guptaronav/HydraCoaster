import SwiftUI

/// Sips for a day, most recent first. Estimated timestamps (coaster
/// couldn't recover a real clock reading) get a quiet "~" rather than a
/// badge. Defaults match TodayView's original copy; History passes its own
/// title/empty text for whichever day is selected. Tapping a row opens a
/// type picker — `onReclassify` commits the change (typeID/factor + Health
/// swap); the default no-op lets previews render without wiring it.
struct SipListSection: View {
    let sips: [SipEvent]
    var title: String = "Today's sips"
    var emptyText: String = "No sips yet today — take one and it'll show up here."
    var onReclassify: (SipEvent, DrinkType) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 4)

            if sips.isEmpty {
                Text(emptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sips.enumerated()), id: \.offset) { index, sip in
                        SipRow(sip: sip, onReclassify: onReclassify)
                        if index != sips.count - 1 {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }
}

private struct SipRow: View {
    let sip: SipEvent
    var onReclassify: (SipEvent, DrinkType) -> Void
    @State private var showingPicker = false

    private var drink: DrinkType { DrinkCatalog.drink(for: sip.typeID) }

    var body: some View {
        Button {
            showingPicker = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: drink.systemImage)
                    .foregroundStyle(Color.hydraAccent)
                    .frame(width: 18)

                Text(sip.date, style: .time)
                    .foregroundStyle(.secondary)

                Spacer()

                amountLabel
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingPicker) {
            ReclassifySheet(currentTypeID: sip.typeID) { newDrink in
                onReclassify(sip, newDrink)
            }
        }
    }

    private var amountLabel: some View {
        HStack(spacing: 4) {
            if sip.isEstimatedDate {
                Text("~")
                    .foregroundStyle(.secondary)
            }
            Text(Int(sip.grams.rounded()), format: .number)
            if sip.hydrationFactor != 1.0 {
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(Int(sip.effectiveGrams.rounded()), format: .number)
            }
            Text("ml")
                .foregroundStyle(.secondary)
        }
        .fontDesign(.rounded)
        .monospacedDigit()
    }
}

/// Standalone type-picker sheet for reclassifying one sip. Wraps the same
/// `DrinkTypeGrid` `LogDrinkSheet` uses for the initial pick — here,
/// tapping a tile commits immediately and dismisses instead of leaving the
/// sheet open for further edits.
private struct ReclassifySheet: View {
    let currentTypeID: String
    var onSelect: (DrinkType) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            Form {
                DrinkTypeGrid(
                    selection: Binding(
                        get: { DrinkCatalog.drink(for: currentTypeID) },
                        set: { newDrink in
                            onSelect(newDrink)
                            dismiss()
                        }
                    ),
                    searchText: searchText
                )
            }
            .searchable(text: $searchText, prompt: "Search drinks")
            .navigationTitle("Change Drink Type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
