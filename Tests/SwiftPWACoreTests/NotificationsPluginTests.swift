import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

@Suite("NotificationsPlugin")
@MainActor
struct NotificationsPluginTests {
    private func makeApp() -> (MockAppContext, MockNotifications) {
        let app = MockAppContext()
        let notif = MockNotifications()
        app.use(NotificationsPlugin(notif))
        return (app, notif)
    }

    @Test("requestAuthorization reports granted=true")
    func authGranted() async throws {
        let (app, notif) = makeApp()
        notif.authorizationGranted = true
        let inv = Invocation(
            id: 1,
            command: "notifications.requestAuthorization",
            payload: Data("{}".utf8)
        )
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(NotificationAuthResult.self, from: data)
        #expect(out.granted == true)
        #expect(notif.actions == [.requestAuthorization])
    }

    @Test("requestAuthorization reports granted=false when denied")
    func authDenied() async throws {
        let (app, notif) = makeApp()
        notif.authorizationGranted = false
        let inv = Invocation(
            id: 1,
            command: "notifications.requestAuthorization",
            payload: Data("{}".utf8)
        )
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(NotificationAuthResult.self, from: data)
        #expect(out.granted == false)
    }

    @Test("notifications.send forwards request and returns the id")
    func send() async throws {
        let (app, notif) = makeApp()
        notif.nextID = { "test-id-7" }
        let request = NotificationRequest(title: "Hello", body: "world", sound: true)
        let payload = try JSONEncoder().encode(request)
        let inv = Invocation(id: 1, command: "notifications.send", payload: payload)
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(NotificationSendResult.self, from: data)
        #expect(out.id == "test-id-7")
        #expect(notif.sent == [request])
    }

    @Test("notifications.send accepts an absent body")
    func sendBodyOptional() async {
        let (app, notif) = makeApp()
        let inv = Invocation(
            id: 1,
            command: "notifications.send",
            payload: Data(#"{"title":"hi","sound":false}"#.utf8)
        )
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case .ok = result else { Issue.record("expected ok"); return }
        #expect(notif.sent.first?.body == nil)
    }
}
