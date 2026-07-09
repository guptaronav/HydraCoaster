import Foundation
import UserNotifications
import os

/// Projects when the *phone* should mirror the coaster's next autonomous
/// buzz. The coaster is the source of truth for timing (it buzzes on its
/// own schedule); this is a best-effort mirror for when the user isn't
/// looking at the coaster. Unlike the interval written to D005, this
/// includes a behavior factor — the phone sees every sip, so it can
/// account for a recent burst of drinking the same way the firmware would.
///
/// `nil` when there's no sip history yet — nothing to mirror.
func nextReminderDate(lastSip: Date?, sips: [SipRecord], intervalS: UInt16, now: Date) -> Date? {
    guard let lastSip else { return nil }
    let behavior = reminderBehaviorFactor(sips: sips, now: now)
    let projected = lastSip.addingTimeInterval(Double(intervalS) * behavior)
    // Past-due (stale connection, phone asleep through the window, etc.):
    // grace period instead of firing instantly.
    return projected > now ? projected : now.addingTimeInterval(120)
}

/// 1.5x if the trailing 60 minutes (up to `now`) already total 250g+ —
/// mirrors the firmware's "already drinking a lot, ease off" behavior.
/// Sips outside that window never contribute, regardless of how large.
private func reminderBehaviorFactor(sips: [SipRecord], now: Date) -> Double {
    let windowStart = now.addingTimeInterval(-60 * 60)
    let trailingTotal = sips
        .filter { $0.date > windowStart && $0.date <= now }
        .reduce(0) { $0 + $1.grams }
    return trailingTotal >= 250 ? 1.5 : 1.0
}

// MARK: - Quiet Hours (V2-T4)

/// Defers `date` to the end of an active quiet window (+15 min) if it falls
/// inside one — the phone-mirror equivalent of D009's firmware-side gating.
/// `startMin`/`endMin` are LOCAL minutes-of-day (unlike the BLE wire format,
/// which is UTC — see `localMinutesToUTCMinutes` below for that
/// conversion). `startMin == endMin` (mode off, or a degenerate manual
/// window) always reads as "no window" and returns `date` unchanged, same
/// as the firmware's own `quietwin::inQuietWindow`.
func applyQuietWindow(date: Date, startMin: Int, endMin: Int, calendar: Calendar = .current) -> Date {
    guard startMin != endMin else { return date }

    let minuteOfDay = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    let inWindow = startMin < endMin
        ? (minuteOfDay >= startMin && minuteOfDay < endMin)
        : (minuteOfDay >= startMin || minuteOfDay < endMin)
    guard inWindow else { return date }

    // The window's end is "today" at endMin unless it wraps past midnight
    // AND `date` is in the pre-midnight portion (minuteOfDay >= startMin) —
    // then the end is tomorrow. (The post-midnight portion, minuteOfDay <
    // endMin, is already on the day the window ends.)
    let endIsTomorrow = startMin > endMin && minuteOfDay >= startMin
    let startOfDay = calendar.startOfDay(for: date)
    let dayOffset: TimeInterval = endIsTomorrow ? 86_400 : 0
    let windowEnd = startOfDay.addingTimeInterval(dayOffset + Double(endMin) * 60)
    return windowEnd.addingTimeInterval(15 * 60)
}

/// Converts a LOCAL minutes-of-day quiet window to UTC minutes-of-day for
/// the D009 write. The firmware's clock is UTC, so converting here — at
/// write time, using the current UTC offset — means every connect/weather-
/// refresh rewrite self-corrects for DST and timezone changes without the
/// firmware ever handling an offset itself (see docs/ble-protocol.md).
func localMinutesToUTCMinutes(startMin: Int, endMin: Int, at date: Date, timeZone: TimeZone = .current) -> (start: UInt16, end: UInt16) {
    let offsetMinutes = timeZone.secondsFromGMT(for: date) / 60
    return (shiftMinuteOfDay(startMin, by: -offsetMinutes), shiftMinuteOfDay(endMin, by: -offsetMinutes))
}

private func shiftMinuteOfDay(_ minute: Int, by delta: Int) -> UInt16 {
    let shifted = (minute + delta) % 1440
    return UInt16(shifted < 0 ? shifted + 1440 : shifted)
}

/// Short, friendly copy for the mirrored reminder. Rounds elapsed time
/// (from `lastSip` to the notification's fire time `at`) to whichever unit
/// reads more naturally.
func reminderBody(lastSip: Date, at date: Date) -> String {
    let elapsedMinutes = max(1, Int((date.timeIntervalSince(lastSip) / 60).rounded()))
    if elapsedMinutes < 60 {
        return "It's been \(elapsedMinutes) min since your last sip."
    }
    let hours = Int((Double(elapsedMinutes) / 60).rounded())
    return "It's been \(hours) hr\(hours == 1 ? "" : "s") since your last sip."
}

/// Thin wrapper around `UNUserNotificationCenter`: one pending mirror
/// notification at a time (constant identifier, replaced not accumulated),
/// suppressed while the app is foregrounded since the coaster itself
/// buzzes regardless of whether the phone is in view.
final class ReminderScheduler: NSObject {
    private static let identifier = "com.ronav.HydraCoaster.reminder"
    private static let testIdentifier = "com.ronav.HydraCoaster.reminder.test"
    private static let snoozeIdentifier = "com.ronav.HydraCoaster.reminder.snooze"
    private static let category = "com.ronav.HydraCoaster.reminderCategory"
    private static let snoozeAction = "com.ronav.HydraCoaster.snoozeAction"
    private static let snoozeMinutes: TimeInterval = 15
    /// Carries `lastSip` (as a Unix timestamp) through the notification's
    /// userInfo so a snooze action — handled well after `reschedule` has
    /// returned — can still compute the snoozed copy's "it's been N min"
    /// body without AppServices being involved.
    private static let lastSipUserInfoKey = "lastSip"

    private let center: UNUserNotificationCenter
    private let logger = Logger(subsystem: "com.ronav.HydraCoaster", category: "ReminderScheduler")

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "Snooze 15 min", options: [])
        let category = UNNotificationCategory(identifier: Self.category, actions: [snooze], intentIdentifiers: [])
        center.setNotificationCategories([category])
    }

    func requestAuthorization() async {
        do {
            try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            logger.error("notification authorization failed: \(error.localizedDescription)")
        }
    }

    /// Replaces any previously scheduled mirror notification with one for
    /// `date`. `lastSip` only feeds the copy — the delivery time is `date`.
    func reschedule(at date: Date, lastSip: Date) {
        let content = Self.content(lastSip: lastSip, fireAt: date)
        let fireIn = max(date.timeIntervalSinceNow, 1)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireIn, repeats: false)
        let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger)

        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.add(request) { [logger] error in
            if let error {
                logger.error("failed to schedule reminder: \(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
    }

    /// Handles the "Snooze 15 min" action: a one-off notification at
    /// now+15min, on its own identifier so it never collides with (or gets
    /// silently replaced by) the next regular mirror reschedule.
    private func scheduleSnooze(lastSip: Date) {
        let fireAt = Date().addingTimeInterval(Self.snoozeMinutes * 60)
        let content = Self.content(lastSip: lastSip, fireAt: fireAt)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.snoozeMinutes * 60, repeats: false)
        let request = UNNotificationRequest(identifier: Self.snoozeIdentifier, content: content, trigger: trigger)
        center.add(request) { [logger] error in
            if let error {
                logger.error("failed to schedule snooze: \(error.localizedDescription)")
            }
        }
    }

    private static func content(lastSip: Date, fireAt: Date) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Time for a sip"
        content.body = reminderBody(lastSip: lastSip, at: fireAt)
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.userInfo = [Self.lastSipUserInfoKey: lastSip.timeIntervalSince1970]
        return content
    }

    /// Debug: fires a sample notification in 5 s. Separate identifier so the
    /// real pending mirror is untouched, and willPresent shows THIS one even
    /// in the foreground so the button visibly works inside the app.
    func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Time for a sip"
        content.body = "Test notification — reminders will look like this."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        let request = UNNotificationRequest(identifier: Self.testIdentifier, content: content, trigger: trigger)
        center.add(request) { [logger] error in
            if let error {
                logger.error("failed to schedule test notification: \(error.localizedDescription)")
            }
        }
    }
}

extension ReminderScheduler: UNUserNotificationCenterDelegate {
    /// The coaster buzzes on its own regardless — no need to also interrupt
    /// whatever the user's looking at in the app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let isTest = notification.request.identifier == Self.testIdentifier
        completionHandler(isTest ? [.banner, .sound] : [])
    }

    /// "Snooze 15 min" action handler.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == Self.snoozeAction else { return }
        guard let epoch = response.notification.request.content.userInfo[Self.lastSipUserInfoKey] as? TimeInterval else { return }
        scheduleSnooze(lastSip: Date(timeIntervalSince1970: epoch))
    }
}
