import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

/// Duplex-session bridge tests: a client opens a session, pushes frames *into*
/// it, and receives downstream events on the same correlated channel
/// (`registerSession` / `BridgeInbound` / the `push` inbound frame).
@Suite("BridgeRuntime duplex sessions")
@MainActor
struct BridgeSessionTests {
    struct EchoOpen: Codable { let prefix: String }
    struct EchoFrame: Codable { let text: String }
    struct EchoEvent: Codable, Equatable { let echo: String }

    /// Registers a `test.echo` session that echoes each pushed frame's `text`
    /// back, prefixed with the open arg, as a downstream event.
    ///
    /// Returns the `app` and `win` too — the caller MUST retain them:
    /// `BridgeRuntime` holds only a `weak` app, and `dispatch` early-returns
    /// once it deallocates.
    private func setUp() async -> (MockAppContext, MockWindow, MockWebView, BridgeRuntime) {
        let app = MockAppContext()
        app.registry.registerSession(
            "test.echo",
            typed: { (open: EchoOpen, inbound: BridgeInbound<EchoFrame>, _)
                -> AsyncThrowingStream<EchoEvent, any Error> in
                AsyncThrowingStream { continuation in
                    let task = Task {
                        for await frame in inbound {
                            continuation.yield(EchoEvent(echo: open.prefix + frame.text))
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        )
        let webView = MockWebView()
        let win = MockWindow(webView: webView)
        app.attach(win)
        let bridge = BridgeRuntime(webView: webView, registry: app.registry, windowID: win.id, app: app)
        bridge.start()
        return (app, win, webView, bridge)
    }

    private func echoEvents(_ webView: MockWebView, id: UInt64) -> [EchoEvent] {
        webView.deliveredFrames.compactMap { frame -> EchoEvent? in
            guard case let .event(eid, chunk) = frame, eid == id else { return nil }
            return try? JSONDecoder().decode(EchoEvent.self, from: chunk)
        }
    }

    @Test("pushed frames echo back as downstream events")
    func pushEchoRoundTrip() async throws {
        let (app, win, webView, bridge) = await setUp()
        defer { withExtendedLifetime((app, win)) { bridge.stop() } }

        try webView.sendSubscribe(id: 400, command: "test.echo", payload: EchoOpen(prefix: ">>"))
        try await waitForCondition { bridge.hasActiveSubscription(id: 400) }

        try webView.sendPush(id: 400, payload: EchoFrame(text: "hi"))
        try webView.sendPush(id: 400, payload: EchoFrame(text: "there"))

        try await waitForCondition { echoEvents(webView, id: 400).count >= 2 }
        #expect(echoEvents(webView, id: 400) == [EchoEvent(echo: ">>hi"), EchoEvent(echo: ">>there")])
    }

    @Test("push before the handler starts consuming is buffered, not lost")
    func pushRaceIsBuffered() async throws {
        let (app, win, webView, bridge) = await setUp()
        defer { withExtendedLifetime((app, win)) { bridge.stop() } }

        // Fire subscribe + push back-to-back with no gating. The serial pump
        // stores the inbound continuation during dispatch before pulling the
        // push frame, and the bounded stream buffers it until the handler's
        // `for await` starts — so the echo must still arrive.
        try webView.sendSubscribe(id: 401, command: "test.echo", payload: EchoOpen(prefix: "#"))
        try webView.sendPush(id: 401, payload: EchoFrame(text: "early"))

        try await waitForCondition { echoEvents(webView, id: 401).count >= 1 }
        #expect(echoEvents(webView, id: 401) == [EchoEvent(echo: "#early")])
    }

    @Test("malformed push frame is dropped without ending the session")
    func malformedPushDropped() async throws {
        let (app, win, webView, bridge) = await setUp()
        defer { withExtendedLifetime((app, win)) { bridge.stop() } }

        try webView.sendSubscribe(id: 402, command: "test.echo", payload: EchoOpen(prefix: "!"))
        try await waitForCondition { bridge.hasActiveSubscription(id: 402) }

        // A frame that doesn't decode to EchoFrame — skipped, session survives.
        webView.send(.push(id: 402, payload: Data(#"{"nope":true}"#.utf8)))
        try webView.sendPush(id: 402, payload: EchoFrame(text: "ok"))

        try await waitForCondition { echoEvents(webView, id: 402).count >= 1 }
        #expect(echoEvents(webView, id: 402) == [EchoEvent(echo: "!ok")])
        #expect(bridge.hasActiveSubscription(id: 402))
    }

    @Test("no more echoes after the client closes the session")
    func closeStopsEchoes() async throws {
        let (app, win, webView, bridge) = await setUp()
        defer { withExtendedLifetime((app, win)) { bridge.stop() } }

        try webView.sendSubscribe(id: 403, command: "test.echo", payload: EchoOpen(prefix: ""))
        try await waitForCondition { bridge.hasActiveSubscription(id: 403) }
        try webView.sendPush(id: 403, payload: EchoFrame(text: "before"))
        try await waitForCondition { echoEvents(webView, id: 403).count >= 1 }

        webView.send(.unsubscribe(id: 403))
        try await waitForCondition { !bridge.hasActiveSubscription(id: 403) }

        let before = echoEvents(webView, id: 403).count
        // A push into the closed session must route nowhere.
        try webView.sendPush(id: 403, payload: EchoFrame(text: "after"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(echoEvents(webView, id: 403).count == before)
    }

    @Test("push to an unknown session id is silently dropped")
    func pushUnknownSession() async throws {
        let (app, win, webView, bridge) = await setUp()
        defer { withExtendedLifetime((app, win)) { bridge.stop() } }

        // No session 999 open — must not crash or deliver anything.
        try webView.sendPush(id: 999, payload: EchoFrame(text: "ghost"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(echoEvents(webView, id: 999).isEmpty)
    }
}
