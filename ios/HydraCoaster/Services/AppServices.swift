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
    /// Same storage seam SyncEngine writes through — needed here to persist
    /// the HealthKit UUID once a write confirms, and to read/update a sip
    /// on reclassify. Not a second writer of new sips: only SyncEngine ever
    /// inserts.
    private let store: SipEventStoring

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
        self.store = store
        self.sips = store.loadAll()

        syncEngine.onNewSip = { [weak self] record in
            self?.handleNewSip(record)
        }
        syncEngine.onHistoryReset = { [weak self] in
            self?.sips = []
            self?.rescheduleReminder() // no sips -> pending reminder cancelled
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

    /// Debug: sample phone notification, fires in ~5 s.
    func sendTestNotification() {
        reminderScheduler.sendTestNotification()
    }

    private func handleNewSip(_ record: SipRecord) {
        sips.append(record)
        rescheduleReminder()
        Task { @MainActor [weak self] in await self?.syncHealthKit(seq: record.seq) }
    }

    /// Reclassifies a stored sip to a new drink type (row tap → type
    /// picker): snapshots the new type/factor onto the record right away —
    /// the row updates immediately — then syncs Apple Health the same way
    /// the initial write does. The store update is synchronous and always
    /// succeeds; the Health swap is best-effort and non-blocking, same as
    /// every other HealthKit write here.
    func reclassify(seq: Int, to drink: DrinkType) {
        guard let current = store.record(seq: seq) else { return }
        store.updateType(seq: seq, typeID: drink.id, hydrationFactor: drink.hydrationFactor)
        if let index = sips.firstIndex(where: { $0.seq == seq }) {
            sips[index] = current.reclassified(to: drink)
        }
        Task { @MainActor [weak self] in await self?.syncHealthKit(seq: seq) }
    }

    /// Writes a sip's CURRENT snapshot to Apple Health, replacing whatever
    /// sample already exists for it. Shared by the initial log and
    /// reclassify — re-reading the store right before the Health call
    /// (rather than acting on a snapshot captured earlier) is what stops a
    /// reclassify that lands while the initial write is still in flight
    /// from being clobbered by it, or vice versa: whichever of the two
    /// calls actually runs its Health I/O last sees the other's effect
    /// already in the store.
    // ponytail: a reclassify landing in the same run-loop turn as the
    // initial log (before either Task gets scheduled) can still race to two
    // Health samples for one sip — not closeable without a per-seq write
    // queue. Not worth it: reaching a stored sip's row to reclassify it
    // requires the initial insert to have already rendered, which in
    // practice is well past that window.
    private func syncHealthKit(seq: Int) async {
        guard let current = store.record(seq: seq) else { return }
        let newUUID = await healthKitLogger.replaceSample(oldUUID: current.hkSampleUUID, with: current)
        store.updateHealthKitUUID(seq: seq, uuid: newUUID)
        if let index = sips.firstIndex(where: { $0.seq == seq }) {
            sips[index] = sips[index].withHealthKitUUID(newUUID)
        }
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
