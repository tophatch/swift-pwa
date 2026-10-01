import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

/// A closing window used to stop its bridge in the same turn it emitted
/// `willClose`, and a quit never closed a window at all, so nothing an app had
/// batched reached disk (#281). These cover the two halves that fix it: the
/// bridge letting a departing document finish, and the Swift handlers' budget.
@Suite("Before close", .serialized)
@MainActor
struct BeforeCloseTests {
    private struct Marker: Codable { let value: String }

    /// Records what reached it. A slow command proves the bridge waits for an
    /// invoke rather than merely accepting it.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [String] = []
        var values: [String] {
            lock.withLock { _values }
        }
        func record(_ value: String) { lock.withLock { _values.append(value) } }
    }

    /// The app comes back too: the bridge holds it weakly, and an app nobody
    /// keeps answers every invoke with nothing.
    private func setUp(_ recorder: Recorder) -> (MockAppContext, MockWebView, BridgeRuntime) {
        let app = MockAppContext()
        app.registry.register("probe.slowWrite", typed: { (args: Marker, _) -> Bool in
            try await Task.sleep(for: .milliseconds(200))
            recorder.record(args.value)
            return true
        })
        let webView = MockWebView()
        let window = MockWindow(webView: webView)
        app.attach(window)
        let bridge = BridgeRuntime(webView: webView, registry: app.registry, windowID: window.id, app: app)
        bridge.start()
        return (app, webView, bridge)
    }

    @Test("an invoke the departing page posted finishes, and isn't cancelled by the next document")
    func departingInvokeFinishes() async throws {
        let recorder = Recorder()
        let (app, webView, bridge) = setUp(recorder)
        defer { bridge.stop(); withExtendedLifetime(app) {} }
        webView.sendHello(epoch: "doc-a")
        try await waitForCondition { bridge.documentEpoch == "doc-a" }

        let started = ContinuousClock.now
        await bridge.letDocumentFinish(until: .now + .seconds(2)) {
            // What the page's `pagehide` handler posts, then the blank
            // document announcing itself — in the order the engine delivers.
            try? webView.sendInvoke(id: 1, command: "probe.slowWrite", payload: Marker(value: "saved"), epoch: "doc-a")
            webView.sendHello(epoch: "blank")
        }

        #expect(recorder.values == ["saved"])
        #expect(ContinuousClock.now - started < .seconds(1), "it should return once the write is done")
    }

    @Test("an ordinary navigation still cancels the old document's invokes")
    func ordinaryNavigationStillCancels() async throws {
        let recorder = Recorder()
        let (app, webView, bridge) = setUp(recorder)
        defer { bridge.stop(); withExtendedLifetime(app) {} }
        webView.sendHello(epoch: "doc-a")
        try webView.sendInvoke(id: 1, command: "probe.slowWrite", payload: Marker(value: "late"), epoch: "doc-a")
        webView.sendHello(epoch: "doc-b")
        try await Task.sleep(for: .milliseconds(400))
        #expect(recorder.values.isEmpty)
    }

    @Test("a page that never leaves doesn't hold the window past the deadline")
    func departureIsBounded() async throws {
        let (app, webView, bridge) = setUp(Recorder())
        defer { bridge.stop(); withExtendedLifetime(app) {} }
        webView.sendHello(epoch: "doc-a")
        try await waitForCondition { bridge.documentEpoch == "doc-a" }

        let started = ContinuousClock.now
        await bridge.letDocumentFinish(until: .now + .milliseconds(150)) {}
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .milliseconds(150))
        #expect(elapsed < .seconds(1))
    }

    @Test("handlers run concurrently, and a hung one doesn't hold the close")
    func handlersAreBounded() async {
        let handlers = CloseHandlers()
        let recorder = Recorder()
        handlers.add { reason in
            try? await Task.sleep(for: .milliseconds(50))
            recorder.record("a \(reason)")
        }
        handlers.add { _ in
            try? await Task.sleep(for: .milliseconds(50))
            recorder.record("b")
        }
        handlers.add { _ in
            // Ignores cancellation, the way a blocking flush would.
            while true { try? await Task.sleep(for: .seconds(10)) }
        }

        let started = ContinuousClock.now
        await handlers.run(.quit, until: .now + .milliseconds(300))
        let elapsed = ContinuousClock.now - started

        #expect(Set(recorder.values) == ["a quit", "b"])
        #expect(elapsed >= .milliseconds(300))
        #expect(elapsed < .seconds(2))
    }

    @Test("with nothing registered, a close doesn't wait at all")
    func noHandlersNoWait() async {
        let started = ContinuousClock.now
        await CloseHandlers().run(.quit, until: .now + .seconds(5))
        #expect(ContinuousClock.now - started < .milliseconds(100))
    }
}
