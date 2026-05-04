import Foundation

/// Cross-platform desktop / mobile notifications. Backends provide a
/// concrete `SystemNotifications` (`SwiftPWAWebKit` and `SwiftPWAGTK`);
/// tests use `MockNotifications` from `_SwiftPWATestSupport`.
///
/// **Scope (v0.2):** authorization request + one-shot send. Click
/// activations, scheduled deliveries, replace-by-id, and notification
/// actions are intentionally deferred — they need delegate plumbing on
/// Apple (`UNUserNotificationCenterDelegate`) and signal subscription
/// on Linux (`ActionInvoked`/`NotificationClosed` D-Bus signals), and
/// fit better in a follow-up that also gives notifications their own
/// `subscribe` stream.
///
/// **Apple caveat:** `UNUserNotificationCenter` requires the host
/// process to have a real bundle identity. From a `swift run`
/// invocation that's not the case, and `requestAuthorization` returns
/// `false` with `errSecMissingEntitlement`-shaped errors. Bundle the
/// app first (`swift run swift-pwa build --target macos`) before
/// expecting banners to appear.
public protocol Notifications: AnyObject, Sendable {
    /// Prompt the user (the first time) to allow notifications.
    /// Returns `true` if notifications are allowed at the time of the
    /// call, `false` otherwise. Repeated invocations don't re-prompt
    /// once the user has decided; they just report the current state.
    func requestAuthorization() async throws -> Bool

    /// Post a notification. Returns the platform's identifier so
    /// callers can correlate it with later events. The id format is
    /// platform-specific: a UUID string on Apple, a numeric D-Bus
    /// notification id (as a string) on Linux.
    func send(_ request: NotificationRequest) async throws -> String
}

// MARK: - DTOs (used by `NotificationsPlugin`)

public struct NotificationRequest: Sendable, Codable, Equatable {
    public var title: String
    public var body: String?
    public var sound: Bool

    public init(title: String, body: String? = nil, sound: Bool = false) {
        self.title = title
        self.body = body
        self.sound = sound
    }
}

public struct NotificationAuthResult: Sendable, Codable, Equatable {
    public var granted: Bool
    public init(granted: Bool) { self.granted = granted }
}

public struct NotificationSendResult: Sendable, Codable, Equatable {
    public var id: String
    public init(id: String) { self.id = id }
}
