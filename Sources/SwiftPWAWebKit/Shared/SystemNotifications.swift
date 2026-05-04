#if os(macOS) || os(iOS)
    import Foundation
    import SwiftPWACore
    import UserNotifications

    /// `Notifications` backed by `UNUserNotificationCenter`. Works on
    /// both macOS and iOS — the framework API is unified across them.
    ///
    /// The Apple framework requires the host process to have a real
    /// bundle identity and notification entitlement. From a `swift run`
    /// invocation that's not satisfied, and `requestAuthorization`
    /// returns an error such as "Notifications are not allowed for
    /// this application". We surface that as a thrown
    /// `BridgeError(code: .handler)` so the JS caller sees an explicit
    /// failure rather than a silent `false`.
    public final class SystemNotifications: Notifications, @unchecked Sendable {
        public init() {}

        public func requestAuthorization() async throws -> Bool {
            let center = UNUserNotificationCenter.current()
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "requestAuthorization failed: \(error.localizedDescription)"
                )
            }
        }

        public func send(_ request: NotificationRequest) async throws -> String {
            let content = UNMutableNotificationContent()
            content.title = request.title
            if let body = request.body { content.body = body }
            if request.sound { content.sound = .default }

            let id = UUID().uuidString
            let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            do {
                try await UNUserNotificationCenter.current().add(req)
            } catch {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "notification delivery failed: \(error.localizedDescription)"
                )
            }
            return id
        }
    }
#endif
