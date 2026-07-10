import Foundation
import Intents
import os

/// Best-effort Focus awareness (V2-T4). iOS never reveals WHICH Focus is
/// active — only whether one is, via `INFocusStatusCenter`, gated behind the
/// `com.apple.developer.focus-status` entitlement. Every accessor here
/// degrades to "not focused" / "not authorized" rather than throwing: a
/// denied, restricted, or (on a free/personal team) unprovisioned Focus API
/// must never block or crash reminder scheduling — see AppServices, which
/// only ever reads `isFocused` after the caller has already checked
/// `respectFocus` is on.
enum FocusStatusGate {
    private static let logger = Logger(subsystem: "com.ronav.HydraCoaster", category: "FocusStatusGate")

    /// The `com.apple.developer.focus-status` entitlement had to be dropped
    /// from the build — a free personal-team provisioning profile can't
    /// carry it, and without the entitlement the Focus API only ever answers
    /// "not authorized". False hides the Settings toggle entirely; flip back
    /// to true (and restore the entitlement in project.yml + the app
    /// .entitlements) if the project moves to a paid developer account.
    static let isSupported = false

    static var authorizationStatus: INFocusStatusAuthorizationStatus {
        INFocusStatusCenter.default.authorizationStatus
    }

    static var isAuthorized: Bool { authorizationStatus == .authorized }

    /// `false` whenever not authorized — "no visibility" reads as "assume
    /// not focused", never as a reason to block scheduling.
    static var isFocused: Bool {
        guard isAuthorized else { return false }
        return INFocusStatusCenter.default.focusStatus.isFocused ?? false
    }

    /// Requests authorization; returns whether it was granted. Called from
    /// Settings when the user turns "Respect Focus" on — never at
    /// onboarding, so there's no surprise permission dialog for someone who
    /// never touches Quiet Hours.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            INFocusStatusCenter.default.requestAuthorization { status in
                if status != .authorized {
                    logger.info("Focus authorization not granted: \(status.rawValue)")
                }
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
