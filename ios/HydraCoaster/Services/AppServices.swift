import Foundation
import Observation

/// T6's single composition point: wires SyncEngine's sip stream and
/// CoasterClient's connection state to HealthKit logging, weather-adjusted
/// D005 writes, and the mirrored reminder notification. Nothing outside
/// this file calls into ReminderScheduler/WeatherService/HealthKitLogger —
/// views and other services stay unaware they exist.
@MainActor
final class AppServices {
    private let client: CoasterClient
    private let reminderScheduler: ReminderScheduler
    let weatherService: WeatherService // exposed for the DEBUG panel
    private let healthKitLogger: HealthKitLogger

    /// Current D005 value (behavior-free). Starts at the firmware default
    /// and only moves once weather is enabled and a fetch succeeds.
    private var intervalS: UInt16 = 1200
    /// Local mirror of stored sips, seeded once from `store` and kept in
    /// sync via `onNewSip` — avoids re-querying SwiftData on every
    /// reschedule (and keeps SwiftData out of anything but the initial load).
    private var sips: [SipRecord]
    /// Reads the user's Reminders toggle (AppSettings.remindOn) — off
    /// silences the coaster (D006 remind bit) AND this phone mirror; a user
    /// who turns reminders off has turned reminders off. Init parameter
    /// (not set-after-init) so the app-start reschedule already respects it.
    private let isRemindEnabled: () -> Bool

    init(
        client: CoasterClient,
        syncEngine: SyncEngine,
        store: SipEventStoring,
        isRemindEnabled: @escaping () -> Bool = { true }
    ) {
        self.client = client
        self.reminderScheduler = ReminderScheduler()
        self.weatherService = WeatherService()
        self.healthKitLogger = HealthKitLogger()
        self.isRemindEnabled = isRemindEnabled
        self.sips = store.loadAll()

        syncEngine.onNewSip = { [weak self] record in
            self?.handleNewSip(record)
        }
        weatherService.onWeatherUpdate = { [weak self] seconds in
            self?.handleWeatherUpdate(seconds)
        }

        watchConnection()
        rescheduleReminder() // once at app start, from stored sips
    }

    /// Notification auth then HealthKit auth, sequential and best-effort.
    /// Called from OnboardingFlow's finish and from RootView at app start
    /// when already onboarded.
    func requestPermissions() async {
        await reminderScheduler.requestAuthorization()
        await healthKitLogger.requestAuthorization()
    }

    /// Called from Settings when the Reminders toggle flips: off cancels the
    /// pending mirror notification immediately, on reschedules from current
    /// state.
    func remindPreferenceDidChange() {
        rescheduleReminder()
    }

    private func handleNewSip(_ record: SipRecord) {
        sips.append(record)
        healthKitLogger.log(record)
        rescheduleReminder()
    }

    private func handleWeatherUpdate(_ seconds: UInt16) {
        intervalS = seconds
        client.write(interval: seconds)
        rescheduleReminder()
    }

    /// Mirrors SyncEngine's own `withObservationTracking` re-arm pattern
    /// (see SyncEngine.watchConnection) to react to every connect/disconnect.
    private func watchConnection() {
        withObservationTracking {
            _ = client.connectionState
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleConnectionChange()
                self?.watchConnection()
            }
        }
    }

    private func handleConnectionChange() {
        guard client.connectionState == .connected else {
            weatherService.stop()
            return
        }
        weatherService.start() // fetches immediately, then every 30 min
        rescheduleReminder()
    }

    private func rescheduleReminder() {
        guard isRemindEnabled() else {
            reminderScheduler.cancel()
            return
        }
        let lastSip = sips.map(\.date).max()
        guard let date = nextReminderDate(lastSip: lastSip, sips: sips, intervalS: intervalS, now: Date()), let lastSip else {
            reminderScheduler.cancel()
            return
        }
        reminderScheduler.reschedule(at: date, lastSip: lastSip)
    }
}
