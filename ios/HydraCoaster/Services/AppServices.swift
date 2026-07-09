import Foundation
import Observation

/// AppSettings' quiet-hours fields, as AppServices needs them — a plain
/// snapshot so this file stays SwiftData-free (see `store` below for why
/// that separation matters). `mode` is a `QuietMode` raw value;
/// `startMin`/`endMin` are LOCAL minutes-of-day and, in sleep mode, ARE the
/// most recently derived window (Settings/App.swift keep them in sync —
/// AppServices never needs to know which mode produced them).
struct QuietHoursSettings {
    let mode: Int
    let startMin: Int
    let endMin: Int
}

/// Read-only snapshot for the Awards tab and Today's streak chip (V2-T3),
/// recomputed on demand from `AppServices`' in-memory sip mirror plus the
/// current base goal — the mirror already lives in memory, so there's
/// nothing worth caching here.
struct AwardsSnapshot {
    let dailyScore: Int
    let currentStreak: Int
    let longestStreak: Int
    /// Badge id -> date first earned. See `Awards.earnedBadges`.
    let badges: [String: Date]
}

/// Read-only snapshot for the History tab's analytics (V2-T5): range
/// charts, the per-drink breakdown, the heatmap, and CSV export all read
/// from this rather than querying SwiftData directly, same reasoning as
/// `AwardsSnapshot`. `dailyTotals` is the FULL, unwindowed history (via
/// `Awards.dailyTotals`) — History's own range/heatmap trimming happens in
/// `Analytics`, not here.
struct HistorySnapshot {
    let sips: [SipRecord]
    let dailyTotals: [DailyTotal]
}

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
    /// Exposed so Settings can request auth + preview-derive the sleep
    /// window interactively; AppServices uses the same instance for its own
    /// background refresh (see `refreshSleepDerivedWindowIfNeeded`).
    let sleepScheduleReader: SleepScheduleReader
    private let healthKitLogger: HealthKitLogger
    /// Same storage seam SyncEngine writes through — needed here to persist
    /// the HealthKit UUID once a write confirms, and to read/update a sip
    /// on reclassify. Not a second writer of new sips: only SyncEngine ever
    /// inserts.
    private let store: SipEventStoring

    /// Weather's own output (behavior- and preset-free) — kept separately
    /// from `intervalS` so a preset change can rewrite D005 without waiting
    /// on the next weather tick.
    private var weatherBaseIntervalS: UInt16 = 1200
    /// Current D005 value: weather base × reminder preset, clamped. This is
    /// also what the phone mirror (`nextReminderDate`) scales by — the
    /// mirror and the coaster's own D005 always agree on cadence.
    private var intervalS: UInt16 = 1200
    /// Local mirror of stored sips, seeded once from `store` and kept in
    /// sync via `onNewSip` — avoids re-querying SwiftData on every
    /// reschedule (and keeps SwiftData out of anything but the initial load).
    private var sips: [SipRecord]
    private var sleepRefreshTask: Task<Void, Never>?

    /// Reads the user's Reminders toggle (AppSettings.remindOn) — off
    /// silences the coaster (D006 remind bit) AND this phone mirror; a user
    /// who turns reminders off has turned reminders off. Init parameter
    /// (not set-after-init) so the app-start reschedule already respects it.
    private let isRemindEnabled: () -> Bool
    private let quietHours: () -> QuietHoursSettings
    private let reminderPreset: () -> Int
    private let respectFocus: () -> Bool
    /// Wraps `FocusStatusGate.isFocused` in production; a fake in tests —
    /// keeps the Intents framework out of the test process, same reasoning
    /// as `SipEventStoring` keeping SwiftData out.
    private let isFocused: () -> Bool
    /// Persists a freshly derived sleep window back into AppSettings (only
    /// meaningful while `quietHours().mode == QuietMode.sleep.rawValue`) —
    /// the one point this file writes AppSettings, funneled through a
    /// closure for the same reason `isRemindEnabled` reads it through one.
    private let saveSleepDerivedWindow: (Int, Int) -> Void
    /// Current base goal in ml (V2-T3) — `AppSettings.goalML`, which already
    /// reflects whichever of manual or personalized the user has picked (see
    /// `Awards.swift` for why streaks/badges want this over the weather-
    /// scaled goal). Funneled through a closure for the same reason
    /// `isRemindEnabled` reads its setting through one.
    private let baseGoalML: () -> Double

    init(
        client: CoasterClient,
        syncEngine: SyncEngine,
        store: SipEventStoring,
        isRemindEnabled: @escaping () -> Bool = { true },
        quietHours: @escaping () -> QuietHoursSettings = { QuietHoursSettings(mode: 0, startMin: 0, endMin: 0) },
        reminderPreset: @escaping () -> Int = { ReminderPreset.standard.rawValue },
        respectFocus: @escaping () -> Bool = { false },
        isFocused: @escaping () -> Bool = { false },
        saveSleepDerivedWindow: @escaping (Int, Int) -> Void = { _, _ in },
        baseGoalML: @escaping () -> Double = { 2000 }
    ) {
        self.client = client
        self.reminderScheduler = ReminderScheduler()
        self.weatherService = WeatherService()
        self.sleepScheduleReader = SleepScheduleReader()
        self.healthKitLogger = HealthKitLogger()
        self.isRemindEnabled = isRemindEnabled
        self.quietHours = quietHours
        self.reminderPreset = reminderPreset
        self.respectFocus = respectFocus
        self.isFocused = isFocused
        self.saveSleepDerivedWindow = saveSleepDerivedWindow
        self.baseGoalML = baseGoalML
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
        Task { @MainActor [weak self] in await self?.refreshSleepDerivedWindowIfNeeded() }
        startDailySleepRefresh()
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

    /// Called from Settings whenever a Quiet Hours field changes (mode,
    /// manual times, or a freshly derived sleep window): rewrites D009 and
    /// reschedules the phone mirror to match.
    func quietSettingsDidChange() {
        writeQuietWindow()
        rescheduleReminder()
    }

    /// Called from Settings when the reminder-frequency preset changes:
    /// rewrites D005 against the last weather base (no need to wait for the
    /// next weather tick) and reschedules the phone mirror.
    func reminderPresetDidChange() {
        applyPresetAndWrite()
    }

    /// Best-effort Focus re-check (V2-T4): Focus status isn't observed via a
    /// delegate (see `FocusStatusGate`'s doc comment) — re-evaluating here,
    /// on every foreground, is the cheap substitute. Call from RootView's
    /// `scenePhase` observer.
    func appDidBecomeActive() {
        rescheduleReminder()
    }

    /// Debug: sample phone notification, fires in ~5 s.
    func sendTestNotification() {
        reminderScheduler.sendTestNotification()
    }

    /// Hydration score, streaks, and badges (V2-T3), built from the in-
    /// memory sip mirror so AwardsView/TodayView never touch SwiftData.
    var awardsSnapshot: AwardsSnapshot {
        let goal = baseGoalML()
        let calendar = Calendar.current
        let now = Date()
        let days = Awards.dailyTotals(from: sips, calendar: calendar)
        let consumedToday = sips
            .filter { calendar.isDateInToday($0.date) }
            .reduce(0) { $0 + $1.effectiveGrams }
        return AwardsSnapshot(
            dailyScore: Awards.dailyScore(consumedML: consumedToday, goalML: goal),
            currentStreak: Awards.currentStreak(days: days, goalML: goal, today: now, calendar: calendar),
            longestStreak: Awards.longestStreak(days: days, goalML: goal, calendar: calendar),
            badges: Awards.earnedBadges(sips: sips, days: days, goalML: goal, calendar: calendar)
        )
    }

    /// Sips + full day bucketing for the History tab (V2-T5), built from
    /// the same in-memory sip mirror `awardsSnapshot` uses.
    var historySnapshot: HistorySnapshot {
        HistorySnapshot(sips: sips, dailyTotals: Awards.dailyTotals(from: sips))
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
        weatherBaseIntervalS = seconds
        applyPresetAndWrite()
        writeQuietWindow() // same 30-min cadence hook re-derives the UTC window (DST/tz drift)
    }

    /// Scales `weatherBaseIntervalS` by the current reminder preset, writes
    /// the result to D005, and reschedules the phone mirror — shared by a
    /// fresh weather reading and an explicit preset change.
    private func applyPresetAndWrite() {
        let preset = ReminderPreset(rawValue: reminderPreset()) ?? .standard
        intervalS = WeatherService.scaledIntervalS(base: weatherBaseIntervalS, preset: preset)
        client.write(interval: intervalS)
        rescheduleReminder()
    }

    /// Converts the effective quiet window to UTC and writes D009. Mode off
    /// (or a degenerate manual window with equal start/end) writes literal
    /// `0,0`, matching the wire convention exactly rather than relying on
    /// callers to notice that any equal-valued pair behaves the same way.
    private func writeQuietWindow() {
        let window = effectiveQuietWindow()
        guard window.start != window.end else {
            client.write(quietWindowStartMin: 0, endMin: 0)
            return
        }
        let utc = localMinutesToUTCMinutes(startMin: window.start, endMin: window.end, at: Date())
        client.write(quietWindowStartMin: utc.start, endMin: utc.end)
    }

    /// `(0, 0)` when the mode is off; otherwise the stored local minutes
    /// (which, in sleep mode, are the most recently derived window).
    private func effectiveQuietWindow() -> (start: Int, end: Int) {
        let qh = quietHours()
        guard qh.mode != QuietMode.off.rawValue else { return (0, 0) }
        return (qh.startMin, qh.endMin)
    }

    /// Re-derives the sleep-based quiet window and persists it, but only
    /// while sleep mode is actually selected — a no-op otherwise, so it's
    /// safe to call unconditionally from app start and the daily loop.
    private func refreshSleepDerivedWindowIfNeeded() async {
        guard quietHours().mode == QuietMode.sleep.rawValue else { return }
        guard let window = await sleepScheduleReader.deriveWindow() else { return }
        saveSleepDerivedWindow(window.startMin, window.endMin)
        writeQuietWindow()
        rescheduleReminder()
    }

    private func startDailySleepRefresh() {
        sleepRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
                await self?.refreshSleepDerivedWindowIfNeeded()
            }
        }
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
        writeQuietWindow() // next to the interval write — see writeQuietWindow's callers
        rescheduleReminder()
    }

    private func rescheduleReminder() {
        guard isRemindEnabled() else {
            reminderScheduler.cancel()
            return
        }
        // Best-effort Focus (V2-T4): no delegate for focus-change events, so
        // this and the app-foreground re-check (appDidBecomeActive) are the
        // only times this gets re-evaluated. Cancelling rather than
        // "deferring" is deliberate — there's no future timer to wake up
        // and reschedule once Focus ends, only the next natural trigger
        // (new sip, reconnect, weather tick, or foreground).
        if respectFocus(), isFocused() {
            reminderScheduler.cancel()
            return
        }
        let lastSip = sips.map(\.date).max()
        guard let date = nextReminderDate(lastSip: lastSip, sips: sips, intervalS: intervalS, now: Date()), let lastSip else {
            reminderScheduler.cancel()
            return
        }
        let window = effectiveQuietWindow()
        let adjusted = applyQuietWindow(date: date, startMin: window.start, endMin: window.end)
        reminderScheduler.reschedule(at: adjusted, lastSip: lastSip)
    }
}
