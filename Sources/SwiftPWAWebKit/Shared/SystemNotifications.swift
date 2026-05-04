#if os(macOS) || os(iOS)
    import Foundation
    import SwiftPWACore
    import UserNotifications

    /// `Notifications` backed by `UNUserNotificationCenter`. Works on
    /// both macOS and iOS — the framework API is unified across them.
    ///
    /// **Bundling caveat.** `UNUserNotificationCenter` requires the host
    /// process to be a real `.app` with a `CFBundleIdentifier`. Calling
    /// `current()` / `requestAuthorization` from a bare `swift run`
    /// process (where `Bundle.main.bundleURL` points at
    /// `.build/.../debug/`) raises an *Objective-C* exception
    /// (`bundleProxyForCurrentProcess is nil`) that Swift's `do/catch`
    /// can't catch — it crashes the app. We pre-flight by checking
    /// `Bundle.main.bundleIdentifier` and throw a clean
    /// `BridgeError(code: .handler)` in that case so the JS caller
    /// sees an actionable failure with bundling instructions.
    public final class SystemNotifications: Notifications, @unchecked Sendable {
        public init() {}

        public func requestAuthorization() async throws -> Bool {
            try ensureBundled()
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
            try ensureBundled()
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

        private func ensureBundled() throws {
            guard Bundle.main.bundleIdentifier != nil else {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: """
                    notifications require a bundled app — `UNUserNotificationCenter` raises an \
                    uncatchable NSException when the host process has no bundle identity. Bundle \
                    with `swift run swift-pwa build --target macos` and launch the resulting \
                    `.app` instead of `swift run`.
                    """
                )
            }
        }
    }
#endif
