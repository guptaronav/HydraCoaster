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

    func log(_ record: SipRecord) {
        guard isAvailable else { return }
        // 1 g = 1 ml (see SyncEngine/DailyTotals — same equivalence used everywhere else).
        let quantity = HKQuantity(unit: .literUnit(with: .milli), doubleValue: record.grams)
        let sample = HKQuantitySample(type: waterType, quantity: quantity, start: record.date, end: record.date)
        store.save(sample) { [logger] success, error in
            if let error {
                logger.error("HealthKit save failed: \(error.localizedDescription)")
            }
        }
    }
}
