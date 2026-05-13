#if os(Android)
    import Foundation
    import SwiftPWACore

    /// `Notifications` backed by `NotificationManagerCompat`. The
    /// Kotlin bridge owns a single notification channel
    /// (`swift-pwa.default`) created lazily on first send — required
    /// since API 26 (Android 8) and silently ignored on older API
    /// levels, so the same code path works for the floor of API 28.
    ///
    /// **Authorization.** API 33+ (Android 13) introduced the
    /// `POST_NOTIFICATIONS` runtime permission. `requestAuthorization`
    /// triggers the system prompt the first time and reports the
    /// resolved state thereafter via
    /// `NotificationManagerCompat.areNotificationsEnabled()`. Older
    /// API levels short-circuit to `true` (no prompt, no gate).
    public final class SystemNotifications: Notifications, @unchecked Sendable {
        public init() {}

        public func requestAuthorization() async throws -> Bool {
            let result: NotificationAuthResult = try await AndroidRPC.call(
                "notifications.requestAuthorization", EmptyArgs()
            )
            return result.granted
        }

        public func send(_ request: NotificationRequest) async throws -> String {
            let result: NotificationSendResult = try await AndroidRPC.call(
                "notifications.send", request
            )
            return result.id
        }
    }
#endif
