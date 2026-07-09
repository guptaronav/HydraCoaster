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
}
