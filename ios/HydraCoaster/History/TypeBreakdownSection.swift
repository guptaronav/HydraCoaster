import SwiftUI

/// "By drink" section (V2-T5): each category's share of the selected range
/// as a proportional capsule bar, sorted by effective ml descending (as
/// `Analytics.typeBreakdown` already returns it) — the longest bar is
/// always full-width, everything else scaled relative to it.
struct TypeBreakdownSection: View {
    let slices: [TypeSlice]

    @Environment(\.hydraTheme) private var theme

    private var maxML: Double { slices.map(\.effectiveML).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("By drink")
                .font(.headline)
                .padding(.horizontal, 4)

            if slices.isEmpty {
                Text("No sips in this range.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            } else {
                VStack(spacing: 16) {
                    ForEach(slices, id: \.categoryName) { slice in
                        row(slice)
                    }
                }
                .padding(20)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
        }
    }

    private func row(_ slice: TypeSlice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(slice.categoryName)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(Int(slice.effectiveML.rounded()), format: .number)
                    .font(.subheadline.monospacedDigit())
                    .fontDesign(.rounded)
                Text("ml")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.hydraAccentSoft)
                    Capsule()
                        .fill(theme.accent)
                        .frame(width: geometry.size.width * fraction(slice))
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
    }

    private func fraction(_ slice: TypeSlice) -> Double {
        guard maxML > 0 else { return 0 }
        return slice.effectiveML / maxML
    }
}

#Preview {
    ScrollView {
        TypeBreakdownSection(slices: [
            TypeSlice(categoryName: "Water & Infusions", effectiveML: 1800, rawML: 1800),
            TypeSlice(categoryName: "Coffee", effectiveML: 620, rawML: 700),
            TypeSlice(categoryName: "Tea", effectiveML: 210, rawML: 220),
        ])
        .padding(20)
    }
}
