import Foundation
import HealthKit
import os

/// Write-only bridge to HealthKit: every stored sip becomes one
/// `dietaryWater` sample, dated to when the sip actually happened (so
/// backfilled sips land at their real time, not "now"). No reads, no
/// authorization status branching beyond "did the write fail" — denial
/// just means `save` reports an error, which is logged and otherwise
/// ignored so a sip is never blocked on Health permission.
final class HealthKitLogger {
    private let store = HKHealthStore()
    private let waterType = HKQuantityType.quantityType(forIdentifier: .dietaryWater)!
    private let logger = Logger(subsystem: "com.ronav.HydraCoaster", category: "HealthKitLogger")

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async {
        guard isAvailable else {
            logger.info("HealthKit unavailable on this device")
            return
        }
        do {
            try await store.requestAuthorization(toShare: [waterType], read: [])
        } catch {
            logger.error("HealthKit authorization request failed: \(error.localizedDescription)")
        }
    }

    /// Writes one `dietaryWater` sample for `record` (effective ml — grams ×
    /// hydrationFactor, 1 g = 1 ml). Returns the created sample's UUID so
    /// the caller can persist it for a later delete-on-reclassify, or nil on
    /// failure/unavailability — logged, never thrown, so a sip is never
    /// blocked on Health permission.
    @discardableResult
    func log(_ record: SipRecord) async -> String? {
        guard isAvailable else { return nil }
        let quantity = HKQuantity(unit: .literUnit(with: .milli), doubleValue: record.effectiveGrams)
        let sample = HKQuantitySample(type: waterType, quantity: quantity, start: record.date, end: record.date)
        return await withCheckedContinuation { continuation in
            store.save(sample) { [logger] success, error in
                if let error {
                    logger.error("HealthKit save failed: \(error.localizedDescription)")
                }
                continuation.resume(returning: success ? sample.uuid.uuidString : nil)
            }
        }
    }

    /// Deletes the sample at `oldUUID` (nil means nothing was ever written —
    /// e.g. a prior save failed) then writes `record`'s current snapshot as
    /// a new sample. Used when a sip is reclassified to a different drink
    /// type, whose effective ml differs from whatever's already in Health.
    /// Same non-blocking contract as `log`.
    func replaceSample(oldUUID: String?, with record: SipRecord) async -> String? {
        if let oldUUID, let uuid = UUID(uuidString: oldUUID) {
            await deleteSample(uuid: uuid)
        }
        return await log(record)
    }

    /// Deletes only work on samples this app wrote — `deleteObjects` needs
    /// just share (write) authorization for the type, not read, matching
    /// the write-only authorization requested above.
    private func deleteSample(uuid: UUID) async {
        guard isAvailable else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.deleteObjects(of: waterType, predicate: HKQuery.predicateForObject(with: uuid)) { [logger] _, _, error in
                if let error {
                    logger.error("HealthKit delete failed: \(error.localizedDescription)")
                }
                continuation.resume()
            }
        }
    }
}
