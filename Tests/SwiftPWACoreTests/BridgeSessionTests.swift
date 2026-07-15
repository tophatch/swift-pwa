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

    @Test("registerSession records its per-command buffer bound")
    func boundRecorded() {
        let registry = CommandRegistry()
        registry.registerSession("s.big", maxBufferedFrames: 512, typed: passthroughSession)
        registry.registerSession("s.small", maxBufferedFrames: 8, typed: passthroughSession)
        registry.registerSession("s.default", typed: passthroughSession)
        registry.register("plain.cmd", typed: { (_: EmptyArgs, _) -> EmptyResult in EmptyResult() })

        #expect(registry.sessionBufferBound(for: "s.big") == 512)
        #expect(registry.sessionBufferBound(for: "s.small") == 8)
        #expect(registry.sessionBufferBound(for: "s.default") == 256)
        #expect(registry.sessionBufferBound(for: "plain.cmd") == nil)
        #expect(registry.sessionBufferBound(for: "nope") == nil)
    }

    struct NumFrame: Codable { let n: Int }
    struct DrainEvent: Codable, Equatable { let n: Int; let dropped: Int }

    @Test("overflowing the bounded buffer drops oldest and counts drops")
    func droppedCountReflectsOverflow() async throws {
        let app = MockAppContext()
        // Gate the handler so it doesn't drain until the flood is fully buffered,
        // making the drop count deterministic (no consume/produce interleaving).
        let gate = Gate()
        app.registry.registerSession(
            "test.bounded",
            maxBufferedFrames: 4,
            typed: { (_: EmptyArgs, inbound: BridgeInbound<NumFrame>, _)
                -> AsyncThrowingStream<DrainEvent, any Error> in
                AsyncThrowingStream { continuation in
                    let task = Task {
                        await gate.wait()
                        for await frame in inbound {
                            continuation.yield(DrainEvent(n: frame.n, dropped: inbound.droppedCount))
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
        defer { withExtendedLifetime((app, win)) { bridge.stop() } }

        try webView.sendSubscribe(id: 500, command: "test.bounded", payload: EmptyArgs())
        try await waitForCondition { bridge.hasActiveSubscription(id: 500) }

        // Flood 10 frames into a 4-deep buffer while the handler is gated: the
        // newest 4 (n=6..9) survive, the oldest 6 (n=0..5) are dropped.
        for n in 0 ..< 10 { try webView.sendPush(id: 500, payload: NumFrame(n: n)) }
        // Let the serial pump route all 10 into the bounded buffer before the
        // handler starts draining (10 trivial synchronous routes).
        try await Task.sleep(for: .milliseconds(40))
        await gate.open()

        let events = { () -> [DrainEvent] in
            webView.deliveredFrames.compactMap { frame -> DrainEvent? in
                guard case let .event(eid, chunk) = frame, eid == 500 else { return nil }
                return try? JSONDecoder().decode(DrainEvent.self, from: chunk)
            }
        }
        try await waitForCondition { events().count >= 4 }
        let drained = events()
        #expect(drained.map(\.n) == [6, 7, 8, 9])
        // Six frames were dropped before the handler drained a single one.
        #expect(drained.allSatisfy { $0.dropped == 6 })
    }
}

/// A trivial passthrough session (non-isolated) used only to exercise bound
/// registration in `boundRecorded`.
private func passthroughSession(
    _: EmptyArgs, _ inbound: BridgeInbound<BridgeSessionTests.EchoFrame>, _: CommandContext
) -> AsyncThrowingStream<BridgeSessionTests.EchoFrame, any Error> {
    AsyncThrowingStream { continuation in
        let task = Task { for await f in inbound { continuation.yield(f) }; continuation.finish() }
        continuation.onTermination = { _ in task.cancel() }
    }
}

/// A one-shot gate for deterministic session tests: the handler awaits `wait()`
/// and the test flips it with `open()` once it has staged the state it wants.
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        opened = true
        for w in waiters { w.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
