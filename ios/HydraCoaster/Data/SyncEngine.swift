import Foundation
import Observation
import os

/// What SyncEngine needs from a coaster connection. `CoasterClient` conforms
/// (see the extension at the bottom of CoasterClient.swift) — kept as a
/// protocol so this file has zero CoreBluetooth dependency.
protocol SipSource: AnyObject {
    var isConnected: Bool { get }
    var sipEvents: AsyncStream<SipPacket> { get }
    func requestBackfill(after seq: UInt32)
}

/// Plain-value mirror of a stored sip, used across the storage seam.
struct SipRecord: Equatable, Sendable {
    let seq: Int
    let date: Date
    let grams: Double
    let isEstimatedDate: Bool
    /// Drink-type snapshot (V2-T2): catalog id and hydration factor AT LOG
    /// TIME, so later catalog tweaks don't rewrite historical totals.
    /// Defaulted to plain water so every pre-V2-T2 call site (tests
    /// included) keeps compiling unchanged. `var` (not `let`) is required
    /// here — a `let` with an inline default can never be overridden by an
    /// initializer parameter, only `var` gets a real, settable default
    /// parameter in the synthesized memberwise init (SE-0242). SipRecord
    /// stays value-semantics-immutable in practice: nothing here ever
    /// mutates a field in place, `reclassified`/`withHealthKitUUID` below
    /// always return a new copy.
    var typeID: String = DrinkCatalog.water.id
    var hydrationFactor: Double = DrinkCatalog.water.hydrationFactor
    /// True for sips logged via the Quick Log sheet rather than the coaster.
    var isManual: Bool = false
    /// Apple Health sample UUID for this sip once HealthKitLogger's write
    /// succeeds — nil until then, and swapped on reclassify.
    var hkSampleUUID: String? = nil

    /// Grams × hydrationFactor — the number that feeds every total (Today
    /// ring, History buckets, HealthKit sample amount). Raw `grams` stays
    /// around for the sip row's "350 ml" label and the reminder scheduler's
    /// burst detection.
    var effectiveGrams: Double { grams * hydrationFactor }
}

extension SipRecord {
    /// New copy with `hkSampleUUID` set — used once HealthKit's write
    /// confirms with a UUID. Every other field carries over unchanged.
    func withHealthKitUUID(_ uuid: String?) -> SipRecord {
        SipRecord(
            seq: seq, date: date, grams: grams, isEstimatedDate: isEstimatedDate,
            typeID: typeID, hydrationFactor: hydrationFactor, isManual: isManual,
            hkSampleUUID: uuid
        )
    }

    /// New copy reclassified to `drink`: typeID/hydrationFactor snapshot
    /// updates to match. Pure — the Health-sample swap and store write this
    /// feeds are the caller's job (see `AppServices.reclassify`).
    func reclassified(to drink: DrinkType) -> SipRecord {
        SipRecord(
            seq: seq, date: date, grams: grams, isEstimatedDate: isEstimatedDate,
            typeID: drink.id, hydrationFactor: drink.hydrationFactor, isManual: isManual,
            hkSampleUUID: hkSampleUUID
        )
    }
}

/// Storage seam between the sync engine and SwiftData.
///
/// Exists because SwiftData store operations trap (EXC_BREAKPOINT inside
/// ModelContext.fetch, no diagnostic) whenever they execute inside a test
/// process on this SDK/simulator combination — the identical code runs
/// correctly in the app process. The app wires in `SwiftDataSipStore`
/// (Models.swift); tests wire in an in-memory fake, keeping SwiftData out of
/// the test process entirely.
@MainActor
protocol SipEventStoring: AnyObject {
    func loadAll() -> [SipRecord]
    func insert(_ record: SipRecord)
    func deleteAll()
    /// Single sip by sequence number, or nil if it no longer exists.
    func record(seq: Int) -> SipRecord?
    /// Persists a reclassify's new type snapshot. Deliberately separate
    /// from `updateHealthKitUUID` (not one combined "update anything"
    /// method) — AppServices has two independent async writers that can
    /// race on the same seq (the initial HealthKit write and a reclassify's
    /// swap); keeping the two fields' writes on two different methods,
    /// each touching only what it means to change, is what stops one from
    /// clobbering the other's field with a stale value.
    func updateType(seq: Int, typeID: String, hydrationFactor: Double)
    /// Persists the Apple Health sample UUID for a sip once a write
    /// confirms. See `updateType`'s note on why this is its own method.
    func updateHealthKitUUID(seq: Int, uuid: String?)
}

/// Bridges the BLE client's sip stream into storage: dedupes by sequence
/// number, maps timestamps, and re-requests backfill from the highest
/// sequence already stored on every reconnect.
///
/// Design constraint carried from firmware: a mid-backfill reconnect just
/// re-requests, so duplicate packets WILL arrive across connects. Unique-seq
/// dedupe is the correctness mechanism here, not delivery ordering.
@Observable
@MainActor
final class SyncEngine {
    private let store: SipEventStoring
    private var source: SipSource?
    private var consumeTask: Task<Void, Never>?

    /// Seqs already stored. Loaded once at init and kept in sync by
    /// `ingest` — this engine is the store's only writer, so the set can't
    /// drift. The `@Attribute(.unique)` on SipEvent.seq remains the
    /// database-level backstop if it somehow does.
    private var knownSeqs: Set<Int>

    /// Extension point for T6 (reminders/notifications): fired once per
    /// newly inserted sip, whether it arrived live or via backfill.
    var onNewSip: ((SipRecord) -> Void)?

    /// Fired after resetHistory() empties the store, so AppServices can drop
    /// its sip mirror and cancel the pending reminder.
    var onHistoryReset: (() -> Void)?

    /// Wipes all stored sips. Call only after the coaster has confirmed its
    /// own log clear (D008 {0x04, ok}) — clearing just the phone would let
    /// the next backfill re-import everything.
    func resetHistory() {
        store.deleteAll()
        knownSeqs.removeAll()
        onHistoryReset?()
    }

    init(store: SipEventStoring) {
        self.store = store
        knownSeqs = Set(store.loadAll().map(\.seq))
    }

    /// Wires the engine to a live client: consumes its sip stream and
    /// requests backfill on every transition to connected.
    ///
    /// Idempotent for the same source, and that matters: TodayView's `.task`
    /// re-fires on every re-appear (tab switch, navigation push/pop), and
    /// cancelling the consumer of an AsyncStream FINISHES the stream — a
    /// second consumption attempt then terminates immediately and every
    /// subsequent packet is silently dropped. One source, one consumer, once.
    func start(with source: SipSource) {
        guard source !== self.source else { return }
        self.source = source
        consumeTask?.cancel()
        consumeTask = Task { @MainActor [weak self] in
            for await packet in source.sipEvents {
                self?.ingest(packet)
            }
        }
        if source.isConnected {
            source.requestBackfill(after: UInt32(maxStoredSeq()))
        }
        watchConnection(source)
    }

    /// Re-arms itself after every change, so each transition to connected —
    /// including repeated reconnects mid-backfill — triggers a fresh
    /// backfill request from the real stored max seq.
    private func watchConnection(_ source: SipSource) {
        withObservationTracking {
            _ = source.isConnected
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let current = self.source else { return }
                if current.isConnected {
                    current.requestBackfill(after: UInt32(self.maxStoredSeq()))
                }
                self.watchConnection(current)
            }
        }
    }

    /// Stores a sip if its sequence isn't already known; ignores the
    /// backfill terminator. Internal (not private) so tests can feed packets
    /// directly without CoreBluetooth in the loop.
    func ingest(_ packet: SipPacket) {
        guard !packet.isTerminator else { return }

        let seq = Int(packet.seq)
        guard !knownSeqs.contains(seq) else {
            Logger(subsystem: "com.ronav.HydraCoaster", category: "SyncEngine")
                .info("ingest: seq=\(seq) already known, skipped")
            return
        }
        Logger(subsystem: "com.ronav.HydraCoaster", category: "SyncEngine")
            .info("ingest: storing seq=\(seq) grams=\(packet.grams)")

        let date: Date
        let isEstimatedDate: Bool
        if packet.unixTs > 0 {
            date = Date(timeIntervalSince1970: TimeInterval(packet.unixTs))
            isEstimatedDate = false
        } else {
            date = Date()
            isEstimatedDate = true
        }

        // Coaster packets carry no type info on the wire — default to
        // plain water; the user can reclassify afterwards.
        let record = SipRecord(
            seq: seq, date: date, grams: packet.grams, isEstimatedDate: isEstimatedDate,
            typeID: DrinkCatalog.water.id, hydrationFactor: DrinkCatalog.water.hydrationFactor,
            isManual: false, hkSampleUUID: nil
        )
        persist(record)
    }

    /// Logs a manually-entered sip (Quick Log sheet): same store + dedupe +
    /// fan-out tail as `ingest`, just sourced from the UI instead of BLE.
    /// `seq` is a negative ms-epoch timestamp — it can never collide with
    /// the coaster's positive uint32 seqs, so no counter state is needed.
    /// `date` is clamped to "now" so a stale sheet can't backdate a sip into
    /// the future.
    func logManualSip(drink: DrinkType, grams: Double, date: Date = Date()) {
        let now = Date()
        let record = SipRecord(
            seq: -Int(now.timeIntervalSince1970 * 1000), date: min(date, now), grams: grams,
            isEstimatedDate: false, typeID: drink.id, hydrationFactor: drink.hydrationFactor,
            isManual: true, hkSampleUUID: nil
        )
        persist(record)
    }

    /// Shared tail for `ingest`/`logManualSip`: persists, marks the seq
    /// known, and fans out `onNewSip` exactly once per newly stored sip —
    /// the single point HealthKit logging and reminder rescheduling hang
    /// off of (see AppServices).
    private func persist(_ record: SipRecord) {
        store.insert(record)
        knownSeqs.insert(record.seq)
        onNewSip?(record)
    }

    /// Highest COASTER sequence number currently stored, or 0 if none are.
    /// Manual sips' negative seqs are excluded — they'd otherwise make this
    /// go negative and crash the `UInt32(...)` backfill request the moment
    /// someone logs a manual sip before ever syncing with the coaster.
    func maxStoredSeq() -> Int {
        knownSeqs.filter { $0 >= 0 }.max() ?? 0
    }

    /// Total effective ml (grams × hydrationFactor) sipped today.
    // ponytail: full load + Swift filter; fine at sip scale, revisit only if
    // the store ever holds years of data.
    func consumedToday() -> Double {
        store.loadAll()
            .filter { Calendar.current.isDateInToday($0.date) }
            .reduce(0) { $0 + $1.effectiveGrams }
    }
}
