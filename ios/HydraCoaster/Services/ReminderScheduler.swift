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

    private let center: UNUserNotificationCenter
    private let logger = Logger(subsystem: "com.ronav.HydraCoaster", category: "ReminderScheduler")

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
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
        let content = UNMutableNotificationContent()
        content.title = "Time for a sip"
        content.body = reminderBody(lastSip: lastSip, at: date)
        content.sound = .default

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
}
