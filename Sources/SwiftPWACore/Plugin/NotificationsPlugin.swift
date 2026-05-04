import Foundation

/// Optional plugin exposing `notifications.*` to JS. Not auto-installed
/// because authorization prompts are intrusive and the underlying
/// frameworks (`UserNotifications` on Apple, `gio-2.0` D-Bus calls on
/// Linux) shouldn't load for apps that don't post notifications. Users
/// opt in:
///
/// ```swift
/// runtime.run { ctx in
///     ctx.use(NotificationsPlugin(SystemNotifications()))
/// }
/// ```
public struct NotificationsPlugin: Plugin {
    public static let pluginName = "notifications"

    private let notifications: any Notifications

    public init(_ notifications: any Notifications) {
        self.notifications = notifications
    }

    public func register(into registry: CommandRegistry, app _: any AppContext) {
        let notifications = notifications

        registry.register(
            "notifications.requestAuthorization",
            typed: { (_: EmptyArgs, _) async throws -> NotificationAuthResult in
                try await NotificationAuthResult(granted: notifications.requestAuthorization())
            }
        )

        registry.register(
            "notifications.send",
            typed: { (args: NotificationRequest, _) async throws -> NotificationSendResult in
                try await NotificationSendResult(id: notifications.send(args))
            }
        )
    }
}
