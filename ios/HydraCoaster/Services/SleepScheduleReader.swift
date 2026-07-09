import Foundation
import HealthKit
import os

/// Pure derivation (V2-T4, testable without HealthKit) of a quiet-hours
/// window from raw sleep-sample intervals. `SleepScheduleReader` below is
/// just the HealthKit-shaped I/O around this — grouping into nights,
/// merging, nap exclusion, and the median all happen here so none of it
/// needs HealthKit in the test process.
enum SleepScheduleDerivation {
    static let minNightHours: TimeInterval = 3 * 60 * 60
    static let minQualifyingNights = 3

    /// One night's merged sleep session (after merging overlapping/adjacent
    /// samples and before the nap-length filter).
    struct Night: Equatable {
        let start: Date
        let end: Date
    }

    /// Groups raw sleep-sample intervals into merged sessions, drops
    /// sessions under `minNightHours` (naps), and returns the median
    /// bed-start and median wake-end (each independently, in LOCAL
    /// minutes-of-day) across the remaining nights. `nil` when fewer than
    /// `minQualifyingNights` remain.
    static func deriveWindow(from intervals: [DateInterval], calendar: Calendar = .current) -> (startMin: Int, endMin: Int)? {
        let nights = mergeIntoNights(intervals)
            .filter { $0.end.timeIntervalSince($0.start) >= minNightHours }
        guard nights.count >= minQualifyingNights else { return nil }

        let startMin = medianMinuteOfDay(nights.map(\.start), calendar: calendar)
        let endMin = medianMinuteOfDay(nights.map(\.end), calendar: calendar)
        return (startMin, endMin)
    }

    /// Classic sorted-interval merge: any interval that starts at or before
    /// the current session's end gets folded into it. Calendar-agnostic on
    /// purpose — a session that crosses midnight is still one contiguous
    /// interval of absolute `Date`s, so no explicit day-boundary handling is
    /// needed here.
    static func mergeIntoNights(_ raw: [DateInterval]) -> [Night] {
        let sorted = raw.sorted { $0.start < $1.start }
        var merged: [Night] = []
        for interval in sorted {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = Night(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(Night(start: interval.start, end: interval.end))
            }
        }
        return merged
    }

    /// Median minute-of-day, but shifted to a noon-to-noon domain before
    /// sorting: a plain minute-of-day median breaks for bedtimes that
    /// straddle midnight (23:30 and 00:15 are 15 minutes apart in reality
    /// but ~1400 minutes apart as raw minute-of-day). Shifting the origin to
    /// noon puts every typical bed-time/wake-time value in one contiguous
    /// range with no wraparound to sort across.
    private static func medianMinuteOfDay(_ dates: [Date], calendar: Calendar) -> Int {
        let shifted = dates.map { shiftedMinuteOfDay($0, calendar: calendar) }.sorted()
        let mid = shifted.count / 2
        let median = shifted.count % 2 == 1 ? shifted[mid] : (shifted[mid - 1] + shifted[mid]) / 2
        return (median + noonMinutes) % 1440
    }

    private static func shiftedMinuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return (minute - noonMinutes + 1440) % 1440
    }

    private static let noonMinutes = 720
}

/// Best-effort "From sleep schedule" quiet-hours source (V2-T4): READ-only
/// HealthKit auth for `sleepAnalysis` alone, requested lazily the first time
/// the user picks this mode in Settings — never at onboarding, so there's no
/// surprise permission dialog for someone who never touches Quiet Hours.
final class SleepScheduleReader {
    private let store = HKHealthStore()
    private let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!
    private let logger = Logger(subsystem: "com.ronav.HydraCoaster", category: "SleepScheduleReader")

    private static let lookbackDays = 14
    /// Value has ANY of these — every "still asleep" category, in-bed
    /// included since a merged in-bed span is at worst a slight overestimate
    /// of the actual sleep window, still far closer than not counting it.
    private static let asleepValues: Set<Int> = [
        HKCategoryValueSleepAnalysis.inBed.rawValue,
        HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        HKCategoryValueSleepAnalysis.asleepCore.rawValue,
        HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
        HKCategoryValueSleepAnalysis.asleepREM.rawValue,
    ]

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Returns whether the system sheet completed without error — HealthKit
    /// never reveals whether READ access was actually granted (only share
    /// access is introspectable), so `true` means "asked", not "granted"; a
    /// denied read just yields empty results from `deriveWindow` later.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: [sleepType])
            return true
        } catch {
            logger.error("sleep authorization request failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Fetches the last 14 days of sleep samples and derives a quiet-hours
    /// window. `nil` when unavailable, the query fails, or there isn't
    /// enough data.
    func deriveWindow(now: Date = Date(), calendar: Calendar = .current) async -> (startMin: Int, endMin: Int)? {
        guard isAvailable, let start = calendar.date(byAdding: .day, value: -Self.lookbackDays, to: now) else { return nil }
        guard let samples = await fetchSamples(since: start) else { return nil }
        let intervals = samples
            .filter { Self.asleepValues.contains($0.value) }
            .map { DateInterval(start: $0.startDate, end: $0.endDate) }
        return SleepScheduleDerivation.deriveWindow(from: intervals, calendar: calendar)
    }

    private func fetchSamples(since start: Date) async -> [HKCategorySample]? {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: [])
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { [logger] _, samples, error in
                if let error {
                    logger.error("sleep query failed: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: samples as? [HKCategorySample] ?? [])
            }
            store.execute(query)
        }
    }
}
