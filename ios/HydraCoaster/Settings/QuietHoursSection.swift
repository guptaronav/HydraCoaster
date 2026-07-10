import Intents
import SwiftUI

/// Quiet Hours settings (V2-T4): Off / Manual / From sleep schedule, plus
/// the best-effort "Respect Focus" toggle. Pure UI glue — every field here
/// is a plain `Binding`, and every side effect (BLE write, phone-mirror
/// reschedule) is one of the two callbacks; this view never touches BLE or
/// UNUserNotificationCenter itself (AppServices' job).
struct QuietHoursSection: View {
    @Binding var quietMode: Int
    @Binding var quietStartMin: Int
    @Binding var quietEndMin: Int
    @Binding var respectFocus: Bool
    var sleepScheduleReader: SleepScheduleReader
    /// Fired after mode, manual times, or a freshly derived sleep window
    /// changes — AppServices rewrites D009 and reschedules the phone mirror.
    var onQuietSettingsChanged: () -> Void

    @State private var sleepDataInsufficient = false
    @State private var focusAuthStatus = FocusStatusGate.authorizationStatus

    private var mode: QuietMode { QuietMode(rawValue: quietMode) ?? .off }

    var body: some View {
        Section {
            Picker("Quiet Hours", selection: modeBinding) {
                Text("Off").tag(QuietMode.off)
                Text("Manual").tag(QuietMode.manual)
                Text("Sleep Schedule").tag(QuietMode.sleep)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            modeDetail

            if FocusStatusGate.isSupported, focusAuthStatus != .restricted {
                Toggle("Respect Focus", isOn: respectFocusBinding)
            }
        } header: {
            Text("Quiet Hours")
        } footer: {
            Text(footerText)
        }
        .onAppear { focusAuthStatus = FocusStatusGate.authorizationStatus }
    }

    @ViewBuilder
    private var modeDetail: some View {
        switch mode {
        case .off:
            EmptyView()
        case .manual:
            DatePicker("Starts", selection: manualStartBinding, displayedComponents: .hourAndMinute)
            DatePicker("Ends", selection: manualEndBinding, displayedComponents: .hourAndMinute)
        case .sleep:
            if sleepDataInsufficient {
                Text("Not enough sleep data yet — wearing a sleep tracker helps.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Bedtime", value: Self.timeLabel(minuteOfDay: quietStartMin))
                LabeledContent("Wake", value: Self.timeLabel(minuteOfDay: quietEndMin))
            }
        }
    }

    private var footerText: String {
        var lines = ["The coaster stays silent during quiet hours; reminders resume once the window ends."]
        if FocusStatusGate.isSupported, focusAuthStatus != .restricted {
            lines.append("iOS already hides notifications during Focus; this also stops HydraCoaster from scheduling them. The coaster still buzzes.")
        }
        return lines.joined(separator: " ")
    }

    private var modeBinding: Binding<QuietMode> {
        Binding(
            get: { mode },
            set: { newValue in
                quietMode = newValue.rawValue
                onQuietSettingsChanged()
                if newValue == .sleep {
                    Task { await requestAndDeriveSleepWindow() }
                }
            }
        )
    }

    /// Requested lazily, exactly once per selection into sleep mode — never
    /// at onboarding, so there's no surprise permission dialog for someone
    /// who never touches Quiet Hours.
    private func requestAndDeriveSleepWindow() async {
        await sleepScheduleReader.requestAuthorization()
        guard let window = await sleepScheduleReader.deriveWindow() else {
            sleepDataInsufficient = true
            return
        }
        sleepDataInsufficient = false
        quietStartMin = window.startMin
        quietEndMin = window.endMin
        onQuietSettingsChanged()
    }

    private var respectFocusBinding: Binding<Bool> {
        Binding(
            get: { respectFocus },
            set: { newValue in
                respectFocus = newValue
                guard newValue else { return }
                Task {
                    await FocusStatusGate.requestAuthorization()
                    focusAuthStatus = FocusStatusGate.authorizationStatus
                }
            }
        )
    }

    private var manualStartBinding: Binding<Date> {
        Binding(
            get: { Self.date(fromMinuteOfDay: quietStartMin) },
            set: { newValue in
                quietStartMin = Self.minuteOfDay(from: newValue)
                onQuietSettingsChanged()
            }
        )
    }

    private var manualEndBinding: Binding<Date> {
        Binding(
            get: { Self.date(fromMinuteOfDay: quietEndMin) },
            set: { newValue in
                quietEndMin = Self.minuteOfDay(from: newValue)
                onQuietSettingsChanged()
            }
        )
    }

    private static func date(fromMinuteOfDay minute: Int) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(minute) * 60)
    }

    private static func minuteOfDay(from date: Date) -> Int {
        let calendar = Calendar.current
        return calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }

    private static func timeLabel(minuteOfDay minute: Int) -> String {
        date(fromMinuteOfDay: minute).formatted(date: .omitted, time: .shortened)
    }
}

#Preview {
    List {
        QuietHoursSection(
            quietMode: .constant(1),
            quietStartMin: .constant(1320),
            quietEndMin: .constant(420),
            respectFocus: .constant(false),
            sleepScheduleReader: SleepScheduleReader(),
            onQuietSettingsChanged: {}
        )
    }
}
