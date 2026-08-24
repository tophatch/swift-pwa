import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

/// A command that never returns until released, so a test can hold one invoke
/// open and see whether anything else can still get through.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var cancelled = false
    func release() { lock.withLock { open = true } }
    var isOpen: Bool {
        lock.withLock { open }
    }
    var sawCancellation: Bool {
        lock.withLock { cancelled }
    }
    func noteCancelled() { lock.withLock { cancelled = true } }

    /// Throws on cancellation, like any well-behaved async handler — the
    /// runtime's `stop()` cancels in-flight work, but cancellation in Swift is
    /// cooperative, so a handler that swallows it still runs to completion.
    func wait() async throws {
        while !isOpen {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@Suite("BridgeRuntime concurrent invokes")
@MainActor
struct BridgeConcurrentInvokeTests {
    private func setUp(_ gate: Gate) -> (MockAppContext, MockWindow, MockWebView, BridgeRuntime) {
        let app = MockAppContext()
        let webView = MockWebView()
        let win = MockWindow(webView: webView)
        app.attach(win)
        app.registry.register("test.block", typed: { (_: EmptyArgs, _) async throws -> EmptyArgs in
            do { try await gate.wait() } catch { gate.noteCancelled(); throw error }
            return EmptyArgs()
        })
        app.registry.register("test.quick", typed: { (_: EmptyArgs, _) async throws -> EmptyArgs in
            EmptyArgs()
        })
        let bridge = BridgeRuntime(
            webView: webView, registry: app.registry, windowID: win.id, app: app
        )
        bridge.start()
        return (app, win, webView, bridge)
    }

    private func replied(_ webView: MockWebView, id: UInt64) -> Bool {
        webView.deliveredFrames.contains { frame in
            if case let .reply(replyID, _, _) = frame, replyID == id { return true }
            if case let .replyError(replyID, _, _) = frame, replyID == id { return true }
            return false
        }
    }

    @Test("control: a quick invoke on its own replies")
    func quickAlone() async throws {
        let gate = Gate()
        let (app, win, webView, bridge) = setUp(gate)
        defer { bridge.stop(); gate.release() }
        withExtendedLifetime((app, win)) {}
        try webView.sendInvoke(id: 42, command: "test.quick", payload: EmptyArgs())
        try await waitFor { replied(webView, id: 42) }
        #expect(replied(webView, id: 42))
    }

    @Test("a pending invoke doesn't block a later one")
    func slowInvokeDoesNotBlockTheBridge() async throws {
        let gate = Gate()
        let (app, win, webView, bridge) = setUp(gate)
        defer { bridge.stop(); gate.release() }
        withExtendedLifetime((app, win)) {}

        // This one parks indefinitely — the shape of `geo.current` waiting on a
        // first-run permission prompt, which is how this bug was found.
        try webView.sendInvoke(id: 1, command: "test.block", payload: EmptyArgs())
        try webView.sendInvoke(id: 2, command: "test.quick", payload: EmptyArgs())

        // The whole point: #2 answers while #1 is still parked. Before invokes
        // were dispatched concurrently this timed out, because the pump awaited
        // each frame inline.
        try await waitFor { replied(webView, id: 2) }
        #expect(replied(webView, id: 2))
        #expect(!replied(webView, id: 1), "the blocked invoke should still be pending")

        gate.release()
        try await waitFor { replied(webView, id: 1) }
    }

    @Test("a blocked invoke doesn't block a subscribe either")
    func slowInvokeDoesNotBlockSubscribe() async throws {
        let gate = Gate()
        let app = MockAppContext()
        let webView = MockWebView()
        let win = MockWindow(webView: webView)
        app.attach(win)
        app.registry.register("test.block", typed: { (_: EmptyArgs, _) async throws -> EmptyArgs in
            try await gate.wait()
            return EmptyArgs()
        })
        app.registry.registerStream(
            "test.stream",
            typed: { (_: EmptyArgs, _) -> AsyncThrowingStream<EmptyArgs, any Error> in
                AsyncThrowingStream { continuation in
                    continuation.yield(EmptyArgs())
                    continuation.finish()
                }
            }
        )
        let bridge = BridgeRuntime(
            webView: webView, registry: app.registry, windowID: win.id, app: app
        )
        bridge.start()
        defer { bridge.stop(); gate.release() }
        withExtendedLifetime((app, win)) {}

        try webView.sendInvoke(id: 10, command: "test.block", payload: EmptyArgs())
        try webView.sendSubscribe(id: 11, command: "test.stream", payload: EmptyArgs())

        try await waitFor {
            webView.deliveredFrames.contains { frame in
                if case let .end(id, _) = frame, id == 11 { return true }
                return false
            }
        }
    }

    @Test("stop cancels an invoke that is still in flight")
    func stopCancelsPendingInvokes() async throws {
        let gate = Gate()
        let (app, win, webView, bridge) = setUp(gate)
        withExtendedLifetime((app, win)) {}

        try webView.sendInvoke(id: 20, command: "test.block", payload: EmptyArgs())
        // Give the pump a moment to pick the frame up and park in the handler.
        try await Task.sleep(for: .milliseconds(50))
        #expect(!replied(webView, id: 20))

        // In-flight invokes are tracked precisely so `stop()` can cancel them,
        // rather than leaving handlers running against a torn-down web view.
        // Cancellation is cooperative, so what's guaranteed is that the handler
        // *observes* it — a handler that swallows cancellation still finishes,
        // which is Swift's contract and not something the runtime can override.
        bridge.stop()
        try await waitFor { gate.sawCancellation }
        #expect(gate.sawCancellation)
    }
}
