import SwiftData
import SwiftUI

/// Goal editor, coaster prefs (mirrored to the device), recalibration
/// entry point, and an about line. The coaster section is inert until
/// connected — the app is the source of truth for prefs, so every local
/// change is also written to D006, and a fresh connect gets one push.
struct SettingsView: View {
    var client: CoasterClient

    @Environment(\.modelContext) private var modelContext
    @State private var settings: AppSettings?
    @State private var showRecalibrate = false
    @State private var buzzConfirmed = false

    private var isConnected: Bool { client.connectionState == .connected }

    var body: some View {
        List {
            Section("Daily Goal") {
                if let settings {
                    GoalPicker(goalML: goalBinding(settings))
                        .padding(.vertical, 8)
                }
            }

            Section {
                Toggle("Sound", isOn: prefsBinding(\.soundOn))
                Toggle("Light", isOn: prefsBinding(\.ledOn))
                Toggle("Reminders", isOn: prefsBinding(\.remindOn))

                Button {
                    client.sendCommand(.buzz)
                } label: {
                    HStack {
                        Text("Buzz Test")
                        if buzzConfirmed {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.hydraAccent)
                        }
                    }
                }

                Button("Recalibrate…") { showRecalibrate = true }
            } header: {
                Text("Coaster")
            } footer: {
                if !isConnected {
                    Text("Connect your coaster to change these settings.")
                }
            }
            .disabled(!isConnected)

            Section("About") {
                LabeledContent("Version", value: appVersion)
                Text("HydraCoaster tracks your sips so hydration takes care of itself.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showRecalibrate) {
            RecalibrateFlow(client: client)
        }
        .task {
            settings = AppSettings.fetchOrCreate(in: modelContext)
            if isConnected { writePrefsToDevice() }
        }
        .onChange(of: client.connectionState) { _, newValue in
            if newValue == .connected { writePrefsToDevice() }
        }
        .onChange(of: client.lastCommandStatus) { _, status in
            guard status?.lastCommand == 0x01, status?.result == .ok else { return }
            buzzConfirmed = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                buzzConfirmed = false
            }
        }
    }

    private func goalBinding(_ settings: AppSettings) -> Binding<Double> {
        Binding(
            get: { settings.goalML },
            set: { newValue in
                settings.goalML = newValue
                try? modelContext.save()
            }
        )
    }

    private func prefsBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings?[keyPath: keyPath] ?? true },
            set: { newValue in
                guard let settings else { return }
                settings[keyPath: keyPath] = newValue
                try? modelContext.save()
                writePrefsToDevice()
            }
        )
    }

    private func writePrefsToDevice() {
        guard let settings else { return }
        client.write(prefs: CoasterPrefs(sound: settings.soundOn, led: settings.ledOn, remind: settings.remindOn))
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
