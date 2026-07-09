import SwiftUI

/// Placeholder debug screen for T3. Real design lands in T4/T5 — this is
/// intentionally a plain List, no styling investment.
struct ConnectionDebugView: View {
    var client: CoasterClient
    var syncEngine: SyncEngine
    var appServices: AppServices
    @Environment(WeatherService.self) private var weather
    @State private var confirmingReset = false
    @State private var awaitingResetAck = false

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

            Section("Weather") {
                if !weather.isEnabled {
                    Text("Disabled — no OWM key configured")
                        .foregroundStyle(.secondary)
                } else if let reading = weather.lastReading {
                    LabeledContent("Temperature", value: String(format: "%.1f °C", reading.tempC))
                    LabeledContent("Humidity", value: String(format: "%.0f%%", reading.humidity))
                    LabeledContent("Factor", value: String(format: "%.2f", weather.lastFactor ?? 1.0))
                    LabeledContent("Interval", value: "\(weather.lastInterval ?? 0) s")
                    if let fetchedAt = weather.lastFetchAt {
                        LabeledContent("Fetched", value: fetchedAt.formatted(date: .omitted, time: .standard))
                    }
                } else {
                    Text("No fetch yet — fetches on coaster connect")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Commands") {
                Button("Buzz Test") {
                    client.sendCommand(.buzz)
                }
                .disabled(client.connectionState != .connected)

                Button("Test Phone Notification") {
                    appServices.sendTestNotification()
                }

                // Requires the coaster: clearing only the phone would let the
                // next backfill re-import everything from the coaster's ring.
                Button("Reset Sip History", role: .destructive) {
                    confirmingReset = true
                }
                .disabled(client.connectionState != .connected || awaitingResetAck)
            }
        }
        .navigationTitle("HydraCoaster")
        .confirmationDialog(
            "Delete all sip history?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) {
                awaitingResetAck = true
                client.sendCommand(.resetSipLog)
            }
        } message: {
            Text("Clears the coaster's log and this phone's history. Apple Health entries are not touched.")
        }
        .onChange(of: client.lastCommandStatus) { _, status in
            guard awaitingResetAck, let status, status.lastCommand == 0x04 else { return }
            awaitingResetAck = false
            if status.result == .ok {
                syncEngine.resetHistory()
            }
        }
    }
}
