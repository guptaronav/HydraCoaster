import Foundation
import SwiftData
import os

/// One recorded sip, mirroring a `SipPacket` from the coaster's Sip Log
/// characteristic. `seq` is the coaster's monotonic packet sequence number —
/// unique so re-delivered packets (backfill re-requested after a mid-sync
/// reconnect) dedupe instead of double-counting.
@Model
final class SipEvent {
    @Attribute(.unique) var seq: Int
    var date: Date
    var grams: Double
    /// True when the coaster couldn't recover a real timestamp for this sip
    /// (`unixTs == 0` on the wire) — `date` is the phone's receipt time, a
    /// same-day approximation, not when the sip actually happened.
    var isEstimatedDate: Bool
    /// Drink-type snapshot (V2-T2). Optional/defaulted so SwiftData's
    /// automatic lightweight migration can add these to an existing store —
    /// see `SipRecord` for why the factor is a snapshot, not a live lookup.
    var typeID: String = DrinkCatalog.water.id
    var hydrationFactor: Double = DrinkCatalog.water.hydrationFactor
    /// True for sips logged via the Quick Log sheet rather than the coaster.
    var isManual: Bool = false
    /// Apple Health sample UUID for this sip, once HealthKitLogger's write
    /// succeeds — nil until then, and swapped on reclassify.
    var hkSampleUUID: String?

    var effectiveGrams: Double { grams * hydrationFactor }

    init(
        seq: Int,
        date: Date,
        grams: Double,
        isEstimatedDate: Bool,
        typeID: String = DrinkCatalog.water.id,
        hydrationFactor: Double = DrinkCatalog.water.hydrationFactor,
        isManual: Bool = false,
        hkSampleUUID: String? = nil
    ) {
        self.seq = seq
        self.date = date
        self.grams = grams
        self.isEstimatedDate = isEstimatedDate
        self.typeID = typeID
        self.hydrationFactor = hydrationFactor
        self.isManual = isManual
        self.hkSampleUUID = hkSampleUUID
    }
}

/// App-wide preferences. Single-row table — always use `fetchOrCreate`
/// rather than inserting directly.
@Model
final class AppSettings {
    var goalML: Double
    var soundOn: Bool
    var ledOn: Bool
    var remindOn: Bool
    /// Personalized-goal inputs (V2-T1). Optional/defaulted so SwiftData's
    /// automatic lightweight migration can add them to an existing store —
    /// see GoalCalculator for how they turn into `goalML`.
    var weightKg: Double?
    var heightCm: Double?
    var activityLevel: Int = 1
    var usePersonalizedGoal: Bool = false

    init(
        goalML: Double = 2000,
        soundOn: Bool = true,
        ledOn: Bool = true,
        remindOn: Bool = true,
        weightKg: Double? = nil,
        heightCm: Double? = nil,
        activityLevel: Int = 1,
        usePersonalizedGoal: Bool = false
    ) {
        self.goalML = goalML
        self.soundOn = soundOn
        self.ledOn = ledOn
        self.remindOn = remindOn
        self.weightKg = weightKg
        self.heightCm = heightCm
        self.activityLevel = activityLevel
        self.usePersonalizedGoal = usePersonalizedGoal
    }

    static func fetchOrCreate(in context: ModelContext) -> AppSettings {
        if let existing = try? context.fetch(FetchDescriptor<AppSettings>()).first {
            return existing
        }
        let settings = AppSettings()
        context.insert(settings)
        return settings
    }
}

extension ModelContainer {
    /// Ephemeral container for previews and the app-under-test: a unique
    /// throwaway store in the temp directory, gone when the sandbox is
    /// cleaned.
    static func ephemeral() throws -> ModelContainer {
        let schema = Schema([SipEvent.self, AppSettings.self])
        let url = URL.temporaryDirectory.appending(path: "ephemeral-\(UUID().uuidString).store")
        let configuration = ModelConfiguration(schema: schema, url: url)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

/// SwiftData-backed implementation of the engine's storage seam (see
/// `SipEventStoring` in SyncEngine.swift for why the seam exists). Thin
/// mapping only — all sync logic lives in SyncEngine.
@MainActor
final class SwiftDataSipStore: SipEventStoring {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func loadAll() -> [SipRecord] {
        let events = (try? modelContext.fetch(FetchDescriptor<SipEvent>())) ?? []
        return events.map(Self.record)
    }

    func insert(_ record: SipRecord) {
        let sip = SipEvent(
            seq: record.seq,
            date: record.date,
            grams: record.grams,
            isEstimatedDate: record.isEstimatedDate,
            typeID: record.typeID,
            hydrationFactor: record.hydrationFactor,
            isManual: record.isManual,
            hkSampleUUID: record.hkSampleUUID
        )
        modelContext.insert(sip)
        do {
            try modelContext.save()
        } catch {
            Logger(subsystem: "com.ronav.HydraCoaster", category: "SipStore")
                .error("save failed for seq=\(record.seq): \(error)")
        }
    }

    func record(seq: Int) -> SipRecord? {
        event(seq: seq).map(Self.record)
    }

    func updateType(seq: Int, typeID: String, hydrationFactor: Double) {
        guard let event = event(seq: seq) else { return }
        event.typeID = typeID
        event.hydrationFactor = hydrationFactor
        save(context: "updateType", seq: seq)
    }

    func updateHealthKitUUID(seq: Int, uuid: String?) {
        guard let event = event(seq: seq) else { return }
        event.hkSampleUUID = uuid
        save(context: "updateHealthKitUUID", seq: seq)
    }

    private func save(context: String, seq: Int) {
        do {
            try modelContext.save()
        } catch {
            Logger(subsystem: "com.ronav.HydraCoaster", category: "SipStore")
                .error("\(context) failed for seq=\(seq): \(error)")
        }
    }

    private func event(seq: Int) -> SipEvent? {
        var descriptor = FetchDescriptor<SipEvent>(predicate: #Predicate { $0.seq == seq })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    private static func record(_ event: SipEvent) -> SipRecord {
        SipRecord(
            seq: event.seq,
            date: event.date,
            grams: event.grams,
            isEstimatedDate: event.isEstimatedDate,
            typeID: event.typeID,
            hydrationFactor: event.hydrationFactor,
            isManual: event.isManual,
            hkSampleUUID: event.hkSampleUUID
        )
    }

    func deleteAll() {
        do {
            try modelContext.delete(model: SipEvent.self)
            try modelContext.save()
        } catch {
            Logger(subsystem: "com.ronav.HydraCoaster", category: "SipStore")
                .error("deleteAll failed: \(error)")
        }
    }
}
