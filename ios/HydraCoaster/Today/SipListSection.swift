import SwiftUI

/// Today's sips, most recent first. Estimated timestamps (coaster couldn't
/// recover a real clock reading) get a quiet "~" rather than a badge.
struct SipListSection: View {
    let sips: [SipEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today's sips")
                .font(.headline)
                .padding(.horizontal, 4)

            if sips.isEmpty {
                Text("No sips yet today — take one and it'll show up here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sips.enumerated()), id: \.offset) { index, sip in
                        SipRow(sip: sip)
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

    var body: some View {
        HStack {
            Text(sip.date, style: .time)
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 2) {
                if sip.isEstimatedDate {
                    Text("~")
                        .foregroundStyle(.secondary)
                }
                Text(Int(sip.grams.rounded()), format: .number)
                Text("ml")
                    .foregroundStyle(.secondary)
            }
            .fontDesign(.rounded)
            .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
