import Foundation

/// One day's total intake. A named struct rather than the tuple this was
/// specced as — arrays of tuples aren't Equatable, and tests need `==`.
/// Bucketing lives in `Awards.dailyTotals` (full history) and
/// `Analytics.rangeTotals` (windowed + zero-filled).
struct DailyTotal: Equatable, Sendable {
    let day: Date
    let totalML: Double
}
