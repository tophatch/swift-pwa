import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

@Suite("BridgeRuntime end-to-end")
@MainActor
struct BridgeRuntimeTests {
    private func setUp() async -> (MockAppContext, MockWindow, MockWebView, BridgeRuntime) {
        let app = MockAppContext()
        app.use(WindowPlugin())
        let webView = MockWebView()
        let win = MockWindow(webView: webView)
        // Manually insert into the app's window map so command resolution
        // by id works (createWindow would create its own MockWebView).
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

    @Test("invoke window.setTitle round-trips a reply frame")
    func invokeRoundTrip() async throws {
        let (_, win, webView, bridge) = await setUp()
        defer { bridge.stop() }

        try webView.sendInvoke(
            id: 100,
            command: "window.setTitle",
            payload: SetTitleArgs(id: nil, title: "from JS")
        )

        // Wait for the reply frame to land in deliveredFrames.
        try await waitFor { webView.deliveredFrames.contains(where: { frame in
            if case let .reply(id, _) = frame, id == 100 { return true }
            return false
        }) }

        #expect(win.title() == "from JS")
        guard case let .reply(id, _) = webView.deliveredFrames.first(where: {
            if case .reply = $0 { true } else { false }
        }) else { Issue.record("expected reply"); return }
        #expect(id == 100)
    }

    @Test("invoke unknown command produces an error reply")
    func invokeUnknown() async throws {
        let (_, _, webView, bridge) = await setUp()
        defer { bridge.stop() }

        try webView.sendInvoke(id: 200, command: "no.such.command", payload: EmptyArgs())
        try await waitFor { webView.deliveredFrames.contains(where: { frame in
            if case .replyError = frame { return true }
            return false
        }) }
        guard case let .replyError(_, err) = webView.deliveredFrames.first(where: {
            if case .replyError = $0 { true } else { false }
        }) else { Issue.record("expected error"); return }
        #expect(err.code == BridgeError.notFound)
    }

    @Test("subscribe pumps events then ends on unsubscribe")
    func subscribeUnsubscribe() async throws {
        let (_, win, webView, bridge) = await setUp()
        defer { bridge.stop() }

        try webView.sendSubscribe(id: 300, command: "window.subscribe", payload: TargetOnlyArgs(id: nil))
        // Wait for the bridge's stream subscription to be established
        // before emitting; otherwise the events race past an empty
        // continuation set on the MockWindow.
        try await waitForCondition { bridge.hasActiveSubscription(id: 300) }

        win.emit(.didFocus)
        win.emit(.didBlur)
        try await waitForCondition {
            webView.deliveredFrames.count(where: { frame in
                if case let .event(id, _) = frame, id == 300 { true } else { false }
            }) >= 2
        }
        // Now unsubscribe; the bridge should not deliver further events.
        webView.send(.unsubscribe(id: 300))
        try await waitForCondition { !bridge.hasActiveSubscription(id: 300) }
        let countBefore = webView.deliveredFrames.count(where: { frame in
            if case let .event(id, _) = frame, id == 300 { true } else { false }
        })
        win.emit(.didFocus)
        try await Task.sleep(for: .milliseconds(50))
        let countAfter = webView.deliveredFrames.count(where: { frame in
            if case let .event(id, _) = frame, id == 300 { true } else { false }
        })
        #expect(countAfter == countBefore)
    }
}

/// Spin until `condition()` becomes true or 2 seconds elapse.
@MainActor
func waitFor(timeout: Duration = .seconds(2), condition: () -> Bool) async throws {
    try await waitForCondition(timeout: timeout, condition)
}

@MainActor
func waitForCondition(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline {
            Issue.record("waitForCondition timed out")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
