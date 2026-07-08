import Foundation
import SwiftData

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

    init(seq: Int, date: Date, grams: Double, isEstimatedDate: Bool) {
        self.seq = seq
        self.date = date
        self.grams = grams
        self.isEstimatedDate = isEstimatedDate
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

    init(goalML: Double = 2000, soundOn: Bool = true, ledOn: Bool = true, remindOn: Bool = true) {
        self.goalML = goalML
        self.soundOn = soundOn
        self.ledOn = ledOn
        self.remindOn = remindOn
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
        return events.map {
            SipRecord(seq: $0.seq, date: $0.date, grams: $0.grams, isEstimatedDate: $0.isEstimatedDate)
        }
    }

    func insert(_ record: SipRecord) {
        let sip = SipEvent(
            seq: record.seq,
            date: record.date,
            grams: record.grams,
            isEstimatedDate: record.isEstimatedDate
        )
        modelContext.insert(sip)
        try? modelContext.save()
    }
}
