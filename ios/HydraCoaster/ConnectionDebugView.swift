import SwiftUI

/// Placeholder debug screen for T3. Real design lands in T4/T5 — this is
/// intentionally a plain List, no styling investment.
struct ConnectionDebugView: View {
    var client: CoasterClient

    var body: some View {
        List {
            Section("Bluetooth") {
                LabeledContent("Manager State", value: "\(client.managerState)")
                LabeledContent("Connection", value: "\(client.connectionState)")
            }

            if let weight = client.latestWeight {
                Section("Live Weight") {
                    LabeledContent("Grams", value: String(format: "%.1f g", weight.grams))
                    LabeledContent("Settled", value: weight.settled ? "yes" : "no")
                    LabeledContent("Cup Present", value: weight.cupPresent ? "yes" : "no")
                    LabeledContent("Clock Synced", value: weight.clockSynced ? "yes" : "no")
                    LabeledContent("Std Dev", value: String(format: "%.1f g", weight.stddev))
                }
            }

            if let battery = client.batteryPercent {
                Section("Battery") {
                    LabeledContent("Level", value: "\(battery)%")
                }
            }

            if let status = client.lastCommandStatus {
                Section("Last Command") {
                    LabeledContent("Command", value: "\(status.lastCommand)")
                    LabeledContent("Result", value: "\(status.result)")
                }
            }

            Section("Commands") {
                Button("Buzz Test") {
                    client.sendCommand(.buzz)
                }
                .disabled(client.connectionState != .connected)
            }
        }
        .navigationTitle("HydraCoaster")
    }
}
