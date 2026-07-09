import SwiftUI

/// Catalog grid, sectioned by category, filtered by `searchText`. Shared by
/// `LogDrinkSheet` (continuous binding — tap swaps `selection`, sheet stays
/// open) and `SipRow`'s reclassify sheet (binding's `set` commits and
/// dismisses) — same picker UI, different commit semantics per caller.
/// Renders `Section`s directly, so it must be used inside a `List`/`Form`.
struct DrinkTypeGrid: View {
    @Binding var selection: DrinkType
    var searchText: String = ""

    @Environment(\.hydraTheme) private var theme

    private static let columns = [GridItem(.adaptive(minimum: 84), spacing: 12)]

    private var categories: [(DrinkCategory, [DrinkType])] {
        DrinkCategory.allCases.compactMap { category in
            let drinks = DrinkCatalog.all.filter { drink in
                drink.category == category
                    && (searchText.isEmpty || drink.name.localizedCaseInsensitiveContains(searchText))
            }
            return drinks.isEmpty ? nil : (category, drinks)
        }
    }

    var body: some View {
        ForEach(categories, id: \.0) { category, drinks in
            Section(category.rawValue) {
                LazyVGrid(columns: Self.columns, spacing: 12) {
                    ForEach(drinks) { drink in
                        tile(for: drink)
                    }
                }
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
        }
    }

    private func tile(for drink: DrinkType) -> some View {
        let isSelected = drink.id == selection.id
        return Button {
            selection = drink
        } label: {
            VStack(spacing: 6) {
                Image(systemName: drink.systemImage)
                    .font(.title3)
                Text(drink.name)
                    .font(.caption2.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .padding(8)
            .background(
                isSelected ? theme.accent : Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}
