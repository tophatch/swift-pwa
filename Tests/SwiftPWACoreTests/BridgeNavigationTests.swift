import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

/// A window outlives the documents loaded into it, but a document's bridge
/// state must not. `bridge.js` mints an epoch per document and announces it
/// with a `hello` frame at document start; these cover what the runtime does
/// with it.
@Suite("Bridge document lifetime")
@MainActor
struct BridgeNavigationTests {
    private func setUp() async -> (MockAppContext, MockWindow, MockWebView, BridgeRuntime) {
        let app = MockAppContext()
        app.use(WindowPlugin())
        app.use(EventsPlugin())
        let webView = MockWebView()
        let win = MockWindow(webView: webView)
        app.attach(win)
        let bridge = BridgeRuntime(
            webView: webView,
            registry: app.registry,
            windowID: win.id,
            app: app
        )
        bridge.start()
        return (app, win, webView, bridge)
    }

    @Test("a new document's hello cancels the previous document's subscriptions")
    func helloCancelsPreviousSubscriptions() async throws {
        let (_, _, webView, bridge) = await setUp()
        defer { bridge.stop() }

        webView.sendHello(epoch: "doc-a")
        try webView.sendSubscribe(
            id: 1,
            command: "events.subscribe",
            payload: ChannelArgs(channel: "prefs"),
            epoch: "doc-a"
        )
        try await waitForCondition { bridge.hasActiveSubscription(id: 1) }

        webView.sendHello(epoch: "doc-b")
        try await waitForCondition { !bridge.hasActiveSubscription(id: 1) }
    }

    @Test("one emit reaches a navigated window once, not once per document loaded")
    func emitIsNotFannedOutToDeadDocuments() async throws {
        let (app, _, webView, bridge) = await setUp()
        defer { bridge.stop() }

        for epoch in ["doc-a", "doc-b", "doc-c"] {
            webView.sendHello(epoch: epoch)
            // Wait for the previous document to be torn down before the next
            // one subscribes, so the emit below can't race a half-done swap.
            try await waitForCondition { !bridge.hasActiveSubscription(id: 1) }
            // Each document subscribes the same channel and, as `bridge.js`
            // allocates from a counter that restarts at 1, the same id.
            try webView.sendSubscribe(
                id: 1,
                command: "events.subscribe",
                payload: ChannelArgs(channel: "prefs"),
                epoch: epoch
            )
            try await waitForCondition { bridge.hasActiveSubscription(id: 1) }
        }

        try app.events.emit("prefs", ChannelArgs(channel: "prefs"))
        try await Task.sleep(for: .milliseconds(100))

        let delivered = webView.deliveredFrames.count { frame in
            if case let .event(id, _, _) = frame, id == 1 { true } else { false }
        }
        #expect(delivered == 1)
    }

    @Test("frames delivered downstream carry the epoch of the document that subscribed")
    func deliveredFramesCarryTheirDocumentEpoch() async throws {
        let (app, _, webView, bridge) = await setUp()
        defer { bridge.stop() }

        webView.sendHello(epoch: "doc-a")
        try webView.sendSubscribe(
            id: 7,
            command: "events.subscribe",
            payload: ChannelArgs(channel: "prefs"),
            epoch: "doc-a"
        )
        try await waitForCondition { bridge.hasActiveSubscription(id: 7) }

        try app.events.emit("prefs", ChannelArgs(channel: "prefs"))
        try await waitForCondition {
            webView.deliveredFrames.contains { frame in
                if case let .event(id, _, _) = frame, id == 7 { true } else { false }
            }
        }

        let event = webView.deliveredFrames.first { frame in
            if case let .event(id, _, _) = frame, id == 7 { true } else { false }
        }
        #expect(event?.epoch == "doc-a")
    }

    @Test("a straggler frame from a retired document cannot touch the live one")
    func retiredDocumentFramesAreDropped() async throws {
        let (_, _, webView, bridge) = await setUp()
        defer { bridge.stop() }

        // Document A subscribes id 1, then the window navigates and document B
        // subscribes id 1 too — the same slot, as the JS counter restarts.
        webView.sendHello(epoch: "doc-a")
        try webView.sendSubscribe(
            id: 1,
            command: "events.subscribe",
            payload: ChannelArgs(channel: "prefs"),
            epoch: "doc-a"
        )
        try await waitForCondition { bridge.hasActiveSubscription(id: 1) }

        webView.sendHello(epoch: "doc-b")
        try await waitForCondition { !bridge.hasActiveSubscription(id: 1) }
        try webView.sendSubscribe(
            id: 1,
            command: "events.subscribe",
            payload: ChannelArgs(channel: "denied"),
            epoch: "doc-b"
        )
        try await waitForCondition { bridge.hasActiveSubscription(id: 1) }

        // Document A's teardown posts an unsubscribe on its way out; arriving
        // late, it names an id that now belongs to document B.
        webView.sendUnsubscribe(id: 1, epoch: "doc-a")
        try await Task.sleep(for: .milliseconds(100))
        #expect(bridge.hasActiveSubscription(id: 1))
    }

    @Test("re-announcing the same epoch is not a navigation")
    func repeatedHelloForTheSameDocumentIsIdempotent() async throws {
        let (_, _, webView, bridge) = await setUp()
        defer { bridge.stop() }

        webView.sendHello(epoch: "doc-a")
        try webView.sendSubscribe(
            id: 1,
            command: "events.subscribe",
            payload: ChannelArgs(channel: "prefs"),
            epoch: "doc-a"
        )
        try await waitForCondition { bridge.hasActiveSubscription(id: 1) }

        webView.sendHello(epoch: "doc-a")
        try await Task.sleep(for: .milliseconds(100))
        #expect(bridge.hasActiveSubscription(id: 1))
    }

    @Test("an epoch-less frame still works, for a caller that has no document")
    func framesWithoutAnEpochAreAccepted() async throws {
        let (_, _, webView, bridge) = await setUp()
        defer { bridge.stop() }

        try webView.sendSubscribe(id: 1, command: "events.subscribe", payload: ChannelArgs(channel: "prefs"))
        try await waitForCondition { bridge.hasActiveSubscription(id: 1) }
    }
}

private struct ChannelArgs: Codable {
    let channel: String
}
