import SwiftUI

/// Guided 3-step recalibration: tare empty, calibrate with a known weight,
/// confirm. Every action button gates on `latestWeight.settled`, and every
/// result comes from the D008 notify via `lastCommandStatus` — never
/// assumed immediate. Cancelable at any step; nothing needs cleanup since
/// the only state is local to this sheet.
struct RecalibrateFlow: View {
    var client: CoasterClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hydraTheme) private var theme

    @State private var step: RecalibrateStep = .emptyCoaster
    @State private var isAwaitingResult = false
    @State private var retryMessage: String?
    @State private var knownGrams = "200"

    private var weight: WeightReading? { client.latestWeight }
    private var isSettled: Bool { weight?.settled ?? false }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                liveReading

                Group {
                    switch step {
                    case .emptyCoaster: emptyCoasterStep
                    case .placeWeight: placeWeightStep
                    case .done: doneStep
                    }
                }

                Spacer()
            }
            .padding(24)
            .navigationTitle("Recalibrate")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: client.lastCommandStatus) { _, status in
                guard let status, let outcome = RecalibrateReducer.handle(status: status, for: step) else { return }
                isAwaitingResult = false
                switch outcome {
                case .advance(let next):
                    retryMessage = nil
                    step = next
                case .retry(let message):
                    retryMessage = message
                }
            }
        }
    }

    private var liveReading: some View {
        VStack(spacing: 6) {
            if let weight {
                Text(weight.grams, format: .number.precision(.fractionLength(1)))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(isSettled ? "Settled" : "Settling…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSettled ? theme.accent : .secondary)
            } else {
                Text("No live reading")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 12)
    }

    private var emptyCoasterStep: some View {
        VStack(spacing: 16) {
            Text("Empty the coaster")
                .font(.title3.weight(.bold))
            Text("Remove any cup, then wait for the reading to settle.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            retryText

            Button(isAwaitingResult ? "Taring…" : "Tare") {
                isAwaitingResult = true
                retryMessage = nil
                client.sendCommand(.tare)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
            .disabled(!isSettled || isAwaitingResult)
        }
    }

    private var placeWeightStep: some View {
        VStack(spacing: 16) {
            Text("Place a known weight")
                .font(.title3.weight(.bold))
            Text("Set an object of known mass on the coaster and enter its weight in grams.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("Grams", text: $knownGrams)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .frame(width: 140)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))

            retryText

            Button(isAwaitingResult ? "Calibrating…" : "Calibrate") {
                // ponytail: plain Double parse, fine for a decimal-pad
                // numeric field; swap for a locale-aware NumberFormatter if
                // this ships to non-"." decimal locales.
                guard let grams = Double(knownGrams), grams > 0 else {
                    retryMessage = "Enter a valid weight in grams."
                    return
                }
                isAwaitingResult = true
                retryMessage = nil
                client.sendCommand(.calibrate(grams: grams))
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
            .disabled(!isSettled || isAwaitingResult)
        }
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(theme.accent)
            Text("Calibration complete")
                .font(.title3.weight(.bold))
            Text("The reading above reflects the new calibration.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
        }
    }

    @ViewBuilder
    private var retryText: some View {
        if let retryMessage {
            Text(retryMessage)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}
