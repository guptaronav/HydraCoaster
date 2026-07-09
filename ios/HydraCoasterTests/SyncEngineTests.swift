import Foundation
import Testing

@testable import HydraCoaster

/// In-memory stand-in for the SwiftData store. The engine's storage seam
/// exists because SwiftData store operations trap (EXC_BREAKPOINT inside
/// ModelContext.fetch, no diagnostic) whenever executed inside a test
/// process on this SDK/simulator combination — verified against standalone
/// and host-app test targets, in-memory and on-disk containers, sync and
/// async tests, with identical code running correctly in the app process.
/// Keeping SwiftData out of the test process entirely is the reliable fix;
/// `SwiftDataSipStore` stays a thin mapping exercised by the running app.
@MainActor
private final class FakeSipStore: SipEventStoring {
    var records: [SipRecord] = []

    func loadAll() -> [SipRecord] { records }
    func insert(_ record: SipRecord) { records.append(record) }
    func deleteAll() { records.removeAll() }

    func record(seq: Int) -> SipRecord? {
        records.first { $0.seq == seq }
    }

    func updateType(seq: Int, typeID: String, hydrationFactor: Double) {
        guard let index = records.firstIndex(where: { $0.seq == seq }) else { return }
        records[index].typeID = typeID
        records[index].hydrationFactor = hydrationFactor
    }

    func updateHealthKitUUID(seq: Int, uuid: String?) {
        guard let index = records.firstIndex(where: { $0.seq == seq }) else { return }
        records[index].hkSampleUUID = uuid
    }
}

/// Fake BLE source: hand-fed AsyncStream, records backfill requests.
@MainActor
private final class FakeSipSource: SipSource {
    var isConnected = false
    let sipEvents: AsyncStream<SipPacket>
    private let continuation: AsyncStream<SipPacket>.Continuation
    var backfillRequests: [UInt32] = []

    init() {
        var c: AsyncStream<SipPacket>.Continuation!
        sipEvents = AsyncStream { c = $0 }
        continuation = c
    }

    func requestBackfill(after seq: UInt32) { backfillRequests.append(seq) }
    func emit(_ packet: SipPacket) { continuation.yield(packet) }
}

@MainActor
struct SyncEngineTests {

    private func makeEngine(preloaded: [SipRecord] = []) -> (SyncEngine, FakeSipStore) {
        let store = FakeSipStore()
        store.records = preloaded
        return (SyncEngine(store: store), store)
    }

    /// Regression: TodayView's `.task` re-fires on every re-appear (tab
    /// switch, navigation), calling start() again. The original start()
    /// cancelled the prior consumer, which FINISHES the AsyncStream — every
    /// sip after the first re-appear was silently dropped (found live on
    /// hardware, 2026-07-08). start() must be idempotent for the same source.
    @Test func start_calledTwiceWithSameSource_keepsConsumingSips() async {
        let (engine, store) = makeEngine()
        let source = FakeSipSource()

        engine.start(with: source)
        engine.start(with: source) // second re-appear — must be a no-op

        source.emit(SipPacket(seq: 9, unixTs: 1_700_000_000, grams: 20.0))
        var spins = 0
        while store.records.isEmpty && spins < 1000 {
            await Task.yield()
            spins += 1
        }

        #expect(store.records.count == 1)
    }

    @Test func ingest_realTimestamp_insertsSipWithExactDateAndNotEstimated() {
        let (engine, store) = makeEngine()
        engine.ingest(SipPacket(seq: 1, unixTs: 1_700_000_000, grams: 42.0))

        #expect(store.records == [
            SipRecord(seq: 1, date: Date(timeIntervalSince1970: 1_700_000_000), grams: 42.0, isEstimatedDate: false)
        ])
    }

    @Test func ingest_zeroTimestamp_marksEstimatedDateApproximatelyNow() {
        let (engine, store) = makeEngine()
        let before = Date()
        engine.ingest(SipPacket(seq: 2, unixTs: 0, grams: 10.0))
        let after = Date()

        #expect(store.records.count == 1)
        #expect(store.records[0].isEstimatedDate == true)
        #expect(store.records[0].date >= before && store.records[0].date <= after)
    }

    @Test func resetHistory_emptiesStoreClearsDedupeAndNotifies() {
        let preloaded = [SipRecord(seq: 3, date: Date(), grams: 30.0, isEstimatedDate: false)]
        let (engine, store) = makeEngine(preloaded: preloaded)
        var resetFired = false
        engine.onHistoryReset = { resetFired = true }

        engine.resetHistory()

        #expect(store.records.isEmpty)
        #expect(engine.maxStoredSeq() == 0)
        #expect(resetFired)
    }

    @Test func ingest_duplicateSeq_insertsOnlyOneRowAndDoesNotCrash() {
        let (engine, store) = makeEngine()
        let packet = SipPacket(seq: 5, unixTs: 1_700_000_000, grams: 15.0)

        engine.ingest(packet)
        engine.ingest(packet) // exact duplicate, e.g. re-delivered after a mid-backfill reconnect

        #expect(store.records.count == 1)
    }

    @Test func ingest_duplicateSeq_acrossReconnect_dedupesAgainstStoredData() {
        // Simulates a fresh connect after relaunch: the sip is already on
        // disk, and the coaster re-sends it during backfill.
        let stored = SipRecord(seq: 9, date: Date(timeIntervalSince1970: 1_700_000_000), grams: 20, isEstimatedDate: false)
        let (engine, store) = makeEngine(preloaded: [stored])

        engine.ingest(SipPacket(seq: 9, unixTs: 1_700_000_000, grams: 20))

        #expect(store.records == [stored])
    }

    @Test func ingest_terminatorPacket_insertsNoRow() {
        let (engine, store) = makeEngine()
        engine.ingest(SipPacket(seq: 0, unixTs: 0, grams: 0))

        #expect(store.records.isEmpty)
    }

    @Test func maxStoredSeq_emptyStore_isZero() {
        let (engine, _) = makeEngine()
        #expect(engine.maxStoredSeq() == 0)
    }

    @Test func maxStoredSeq_nonEmptyStore_isHighestSeq() {
        let (engine, _) = makeEngine()
        engine.ingest(SipPacket(seq: 3, unixTs: 1_700_000_000, grams: 10))
        engine.ingest(SipPacket(seq: 7, unixTs: 1_700_000_100, grams: 12))
        engine.ingest(SipPacket(seq: 5, unixTs: 1_700_000_050, grams: 9))

        #expect(engine.maxStoredSeq() == 7)
    }

    @Test func consumedToday_sumsOnlyTodaysSips() {
        let (engine, _) = makeEngine()
        let now = UInt32(Date().timeIntervalSince1970)
        let twoDaysAgo = now - UInt32(2 * 24 * 60 * 60)

        engine.ingest(SipPacket(seq: 1, unixTs: now, grams: 100))
        engine.ingest(SipPacket(seq: 2, unixTs: twoDaysAgo, grams: 500))

        #expect(engine.consumedToday() == 100)
    }

    @Test func onNewSip_firesOncePerNewSip_notForDuplicates() {
        let (engine, _) = makeEngine()
        var seen: [Int] = []
        engine.onNewSip = { seen.append($0.seq) }

        engine.ingest(SipPacket(seq: 1, unixTs: 1_700_000_000, grams: 10))
        engine.ingest(SipPacket(seq: 1, unixTs: 1_700_000_000, grams: 10))
        engine.ingest(SipPacket(seq: 2, unixTs: 1_700_000_100, grams: 12))

        #expect(seen == [1, 2])
    }

    // MARK: - V2-T2: drink types

    @Test func ingest_coasterPacket_defaultsToWater() {
        let (engine, store) = makeEngine()
        engine.ingest(SipPacket(seq: 1, unixTs: 1_700_000_000, grams: 42.0))

        #expect(store.records.first?.typeID == DrinkCatalog.water.id)
        #expect(store.records.first?.hydrationFactor == 1.0)
        #expect(store.records.first?.isManual == false)
    }

    @Test func logManualSip_storesIsManualAndCatalogSnapshot() {
        let (engine, store) = makeEngine()
        let coffee = DrinkCatalog.drink(for: "coffee.black")

        engine.logManualSip(drink: coffee, grams: 200)

        #expect(store.records.count == 1)
        #expect(store.records[0].isManual == true)
        #expect(store.records[0].typeID == "coffee.black")
        #expect(store.records[0].hydrationFactor == coffee.hydrationFactor)
    }

    @Test func logManualSip_seqIsNegative_andCantCollideWithCoasterSeqs() {
        let (engine, store) = makeEngine()
        engine.logManualSip(drink: DrinkCatalog.water, grams: 100)

        #expect(store.records[0].seq < 0)
        // The coaster's seq is a uint32 — always >= 0 — so a negative
        // manual seq can never equal one, regardless of value.
        #expect(!(0...Int(UInt32.max)).contains(store.records[0].seq))
    }

    @Test func logManualSip_twoCalls_produceDifferentSeqs() {
        let (engine, store) = makeEngine()
        engine.logManualSip(drink: DrinkCatalog.water, grams: 100)
        // Guarantee a distinct millisecond so the two ms-epoch-derived seqs differ.
        Thread.sleep(forTimeInterval: 0.002)
        engine.logManualSip(drink: DrinkCatalog.water, grams: 200)

        #expect(store.records.count == 2)
        #expect(store.records[0].seq != store.records[1].seq)
    }

    @Test func logManualSip_futureDate_clampedToNow() {
        let (engine, store) = makeEngine()
        let farFuture = Date().addingTimeInterval(3600)
        let before = Date()

        engine.logManualSip(drink: DrinkCatalog.water, grams: 100, date: farFuture)

        #expect(store.records[0].date <= Date())
        #expect(store.records[0].date >= before)
    }

    @Test func consumedToday_usesEffectiveMlNotRawGrams() {
        let (engine, _) = makeEngine()
        let wine = DrinkCatalog.drink(for: "alcohol.wineRed") // hydrationFactor 0.4

        engine.logManualSip(drink: wine, grams: 100)

        #expect(engine.consumedToday() == 40)
    }

    @Test func reclassify_pureFunction_updatesTypeAndFactorOnly() {
        let original = SipRecord(
            seq: 1, date: Date(timeIntervalSince1970: 1_700_000_000), grams: 350,
            isEstimatedDate: false, typeID: DrinkCatalog.water.id, hydrationFactor: 1.0,
            isManual: true, hkSampleUUID: "abc-123"
        )
        let coffee = DrinkCatalog.drink(for: "coffee.black")

        let reclassified = original.reclassified(to: coffee)

        #expect(reclassified.typeID == "coffee.black")
        #expect(reclassified.hydrationFactor == coffee.hydrationFactor)
        #expect(reclassified.seq == original.seq)
        #expect(reclassified.date == original.date)
        #expect(reclassified.grams == original.grams)
        #expect(reclassified.isManual == original.isManual)
        #expect(reclassified.hkSampleUUID == original.hkSampleUUID) // caller swaps this separately
        #expect(reclassified.effectiveGrams == 350 * coffee.hydrationFactor)
    }

    @Test func withHealthKitUUID_pureFunction_updatesUUIDOnly() {
        let original = SipRecord(seq: 1, date: Date(), grams: 100, isEstimatedDate: false)
        let updated = original.withHealthKitUUID("new-uuid")

        #expect(updated.hkSampleUUID == "new-uuid")
        #expect(updated.typeID == original.typeID)
        #expect(updated.grams == original.grams)
    }
}
