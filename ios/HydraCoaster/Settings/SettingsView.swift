import SwiftData
import SwiftUI

/// Goal editor, coaster prefs (mirrored to the device), recalibration
/// entry point, and an about line. The coaster section is inert until
/// connected — the app is the source of truth for prefs, so every local
/// change is also written to D006, and a fresh connect gets one push.
struct SettingsView: View {
    var client: CoasterClient
    var appServices: AppServices

    @Environment(\.modelContext) private var modelContext
    @Environment(\.hydraTheme) private var theme
    @State private var settings: AppSettings?
    @State private var showRecalibrate = false
    @State private var showPersonalize = false
    @State private var buzzConfirmed = false
    @State private var celebrateConfirmed = false

    private var isConnected: Bool { client.connectionState == .connected }

    #if DEBUG
    /// Screenshot aid only: `HC_SHOW_PERSONALIZE=1` opens the personalize
    /// sheet at launch so the gate can capture it without simulating a tap.
    private static var showPersonalizeAtLaunch: Bool {
        ProcessInfo.processInfo.environment["HC_SHOW_PERSONALIZE"] == "1"
    }
    #endif

    var body: some View {
        List {
            Section("Daily Goal") {
                if let settings {
                    GoalPicker(
                        goalML: goalMLBinding,
                        isPersonalized: binding(settings, \.usePersonalizedGoal),
                        onCalculateForMe: { showPersonalize = true }
                    )
                    .padding(.vertical, 8)
                }
            }

            Section("Appearance") {
                if let settings {
                    ThemeSwatchPicker(selection: themeBinding)
                        .padding(.vertical, 4)

                    Picker("Color Scheme", selection: binding(settings, \.appearance)) {
                        ForEach(Appearance.allCases, id: \.self) { option in
                            Text(option.name).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            if let settings {
                QuietHoursSection(
                    quietMode: binding(settings, \.quietMode),
                    quietStartMin: binding(settings, \.quietStartMin),
                    quietEndMin: binding(settings, \.quietEndMin),
                    respectFocus: binding(settings, \.respectFocus),
                    sleepScheduleReader: appServices.sleepScheduleReader,
                    onQuietSettingsChanged: { appServices.quietSettingsDidChange() }
                )
            }

            Section {
                Toggle("Sound", isOn: prefsBinding(\.soundOn))
                Toggle("Light", isOn: prefsBinding(\.ledOn))
                Toggle("Reminders", isOn: prefsBinding(\.remindOn))

                Picker("Reminder frequency", selection: presetBinding) {
                    Text("Gentle").tag(ReminderPreset.gentle.rawValue)
                    Text("Standard").tag(ReminderPreset.standard.rawValue)
                    Text("Persistent").tag(ReminderPreset.persistent.rawValue)
                }
                .pickerStyle(.segmented)

                Button {
                    client.sendCommand(.buzz)
                } label: {
                    HStack {
                        Text("Buzz Test")
                        if buzzConfirmed {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(theme.accent)
                        }
                    }
                }

                // Unlike Buzz Test, this respects the Sound/Light toggles
                // above — both off means the coaster accepts (checkmark)
                // but stays silent and dark, same as a real celebration.
                Button {
                    client.sendCommand(.celebrate)
                } label: {
                    HStack {
                        Text("Celebration Test")
                        if celebrateConfirmed {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(theme.accent)
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
        .sheet(isPresented: $showPersonalize) {
            if let settings {
                PersonalGoalEditor(
                    weightKg: binding(settings, \.weightKg),
                    heightCm: binding(settings, \.heightCm),
                    activityLevel: binding(settings, \.activityLevel),
                    usePersonalizedGoal: binding(settings, \.usePersonalizedGoal),
                    goalML: goalMLBinding
                )
            }
        }
        .task {
            settings = AppSettings.fetchOrCreate(in: modelContext)
            if isConnected { writePrefsToDevice() }
            #if DEBUG
            if Self.showPersonalizeAtLaunch { showPersonalize = true }
            #endif
        }
        .onChange(of: client.connectionState) { _, newValue in
            if newValue == .connected { writePrefsToDevice() }
        }
        .onChange(of: client.lastCommandStatus) { _, status in
            guard let status, status.result == .ok else { return }
            switch status.lastCommand {
            case 0x01:
                buzzConfirmed = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    buzzConfirmed = false
                }
            case 0x05:
                celebrateConfirmed = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    celebrateConfirmed = false
                }
            default:
                break
            }
        }
    }

    /// Generic local-only binding into a settled `AppSettings` row: reads the
    /// live value, writes it back plus a save. No BLE side effects — that's
    /// `prefsBinding`'s job for the coaster-mirrored toggles below.
    private func binding<Value>(_ settings: AppSettings, _ keyPath: ReferenceWritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                settings[keyPath: keyPath] = newValue
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
                if keyPath == \.remindOn {
                    // Off cancels the phone's mirror notification too; on
                    // reschedules it — the coaster's D006 bit alone isn't
                    // "reminders off" from the user's point of view.
                    appServices.remindPreferenceDidChange()
                }
            }
        )
    }

    /// Reminder frequency preset (V2-T4): local save + a D005 rewrite, no
    /// direct BLE call here — `reminderPresetDidChange()` reads the setting
    /// back through its own closure (see AppServices) and applies it
    /// against the last weather base.
    private var presetBinding: Binding<Int> {
        Binding(
            get: { settings?.reminderPreset ?? ReminderPreset.standard.rawValue },
            set: { newValue in
                guard let settings else { return }
                settings.reminderPreset = newValue
                try? modelContext.save()
                appServices.reminderPresetDidChange()
            }
        )
    }

    /// Daily goal (V2-T6): local save + a widget reload — the widget shows
    /// today's progress against this goal, so a change here needs the same
    /// nudge as a fresh sip. Used by both `GoalPicker` and
    /// `PersonalGoalEditor`'s live-preview writes instead of the generic
    /// `binding(_:_:)` helper, which has no side-effect hook.
    private var goalMLBinding: Binding<Double> {
        Binding(
            get: { settings?.goalML ?? 2000 },
            set: { newValue in
                guard let settings else { return }
                settings.goalML = newValue
                try? modelContext.save()
                appServices.widgetRelevantSettingsDidChange()
            }
        )
    }

    /// Color theme (V2-T6): local save + a widget reload, same reasoning as
    /// `goalMLBinding` — the widget's ring is tinted from this raw value.
    private var themeBinding: Binding<Int> {
        Binding(
            get: { settings?.theme ?? Theme.aqua.rawValue },
            set: { newValue in
                guard let settings else { return }
                settings.theme = newValue
                try? modelContext.save()
                appServices.widgetRelevantSettingsDidChange()
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

/// Swatch row for `Theme` (V2-T6): each circle previews its own accent
/// color directly, so the picker doubles as a live preview — no separate
/// color key needed.
private struct ThemeSwatchPicker: View {
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 18) {
            ForEach(Theme.allCases, id: \.self) { candidate in
                swatch(for: candidate)
            }
        }
    }

    private func swatch(for candidate: Theme) -> some View {
        let isSelected = selection == candidate.rawValue
        return Button {
            selection = candidate.rawValue
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(candidate.accent)
                    .frame(width: 32, height: 32)
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(isSelected ? candidate.accent : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1)
                            .frame(width: 38, height: 38)
                    }
                Text(candidate.name)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
