import Foundation
import Observation

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

    init(store: SipEventStoring) {
        self.store = store
        knownSeqs = Set(store.loadAll().map(\.seq))
    }

    /// Wires the engine to a live client: consumes its sip stream and
    /// requests backfill on every transition to connected. Safe to call more
    /// than once — cancels any prior consumption task first.
    func start(with source: SipSource) {
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
        guard !knownSeqs.contains(seq) else { return }

        let date: Date
        let isEstimatedDate: Bool
        if packet.unixTs > 0 {
            date = Date(timeIntervalSince1970: TimeInterval(packet.unixTs))
            isEstimatedDate = false
        } else {
            date = Date()
            isEstimatedDate = true
        }

        let record = SipRecord(seq: seq, date: date, grams: packet.grams, isEstimatedDate: isEstimatedDate)
        store.insert(record)
        knownSeqs.insert(seq)
        onNewSip?(record)
    }

    /// Highest sequence number currently stored, or 0 if the store is empty.
    func maxStoredSeq() -> Int {
        knownSeqs.max() ?? 0
    }

    /// Total grams (== ml) sipped today, 1 g = 1 ml.
    // ponytail: full load + Swift filter; fine at sip scale, revisit only if
    // the store ever holds years of data.
    func consumedToday() -> Double {
        store.loadAll()
            .filter { Calendar.current.isDateInToday($0.date) }
            .reduce(0) { $0 + $1.grams }
    }
}
