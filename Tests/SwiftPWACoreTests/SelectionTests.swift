import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

@Suite("selection.* — page items in the selection menu, selection gestures")
@MainActor
struct SelectionTests {
    private func makeApp() throws -> (MockAppContext, MockWindow) {
        let app = MockAppContext()
        app.use(SelectionPlugin())
        let win = try app.createWindow(WindowConfig(
            title: "T",
            size: Size(width: 200, height: 100),
            content: .remote(URL(string: "about:blank")!)
        )) as! MockWindow
        return (app, win)
    }

    private func dispatch(
        _ command: String, on app: MockAppContext, caller: CommandCaller, payload: String = "{}"
    ) async -> InvocationResult {
        let inv = Invocation(id: 1, command: command, payload: Data(payload.utf8))
        return await app.registry.dispatch(CommandContext(invocation: inv, caller: caller, appContext: app))
    }

    private func selection(of win: MockWindow) -> WebViewSelection {
        (win.webView as! MockWebView).stubbedSelection!
    }

    private func object(_ data: Data) -> [String: String]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }

    @Test("setActions reaches the calling window's webview, in order")
    func setActions() async throws {
        let (app, win) = try makeApp()
        let result = await dispatch(
            "selection.setActions", on: app, caller: .page(win.id),
            payload: #"{"actions":[{"id":"highlight","title":"Highlight"},{"id":"note","title":"Note"}]}"#
        )
        guard case .ok = result else { Issue.record("expected ok, got \(result)"); return }
        #expect(selection(of: win).actions == [
            SelectionAction(id: "highlight", title: "Highlight"),
            SelectionAction(id: "note", title: "Note")
        ])
    }

    @Test("an empty id or title, or an id used twice, is refused and changes nothing")
    func setActionsValidates() async throws {
        let (app, win) = try makeApp()
        _ = await dispatch(
            "selection.setActions", on: app, caller: .page(win.id),
            payload: #"{"actions":[{"id":"keep","title":"Keep"}]}"#
        )
        for bad in [
            #"{"actions":[{"id":"","title":"X"}]}"#,
            #"{"actions":[{"id":"x","title":""}]}"#,
            #"{"actions":[{"id":"a","title":"A"},{"id":"a","title":"B"}]}"#
        ] {
            let result = await dispatch("selection.setActions", on: app, caller: .page(win.id), payload: bad)
            guard case let .failure(error) = result else { Issue.record("accepted \(bad)"); continue }
            #expect(error.code == BridgeError.decode)
        }
        #expect(selection(of: win).actions == [SelectionAction(id: "keep", title: "Keep")])
    }

    @Test("a backend that has to be told about a change can fail the page's call")
    func actionsChangedFailurePropagates() async throws {
        struct Refused: Error {}
        let selection = WebViewSelection { _ in throw Refused() }
        await #expect(throws: Refused.self) {
            try await selection.setActions([SelectionAction(id: "a", title: "A")])
        }
    }

    @Test("subscribe delivers chosen actions and gesture changes, encoded for the page")
    func subscribeDelivers() async throws {
        let (app, win) = try makeApp()
        let result = await dispatch("selection.subscribe", on: app, caller: .page(win.id))
        guard case let .stream(stream) = result else { Issue.record("expected stream"); return }
        let selection = selection(of: win)
        while selection.subscriberCount == 0 {
            await Task.yield()
        }
        selection.gesture(.began)
        selection.gesture(.began)
        selection.actionChosen("highlight")
        selection.gesture(.ended)
        selection.gesture(.ended)

        var received: [[String: String]] = []
        for try await chunk in stream {
            if let event = object(chunk) { received.append(event) }
            if received.count == 3 { break }
        }
        // Repeats of the current phase are dropped, so a backend with two
        // sources for one finger can't report it twice.
        #expect(received == [
            ["type": "gesture", "phase": "began"],
            ["type": "action", "id": "highlight"],
            ["type": "gesture", "phase": "ended"]
        ])
    }

    @Test("the mouse path from bridge.js lands on the same per-window stream")
    func pointerGesture() async throws {
        let (app, win) = try makeApp()
        let events = selection(of: win).events()
        let result = await dispatch(
            SelectionPlugin.pointerGestureCommand, on: app, caller: .page(win.id), payload: #"{"phase":"began"}"#
        )
        guard case .ok = result else { Issue.record("expected ok, got \(result)"); return }
        for await event in events {
            #expect(event == .gesture(.began))
            break
        }
    }

    @Test("an agent (no window) is refused rather than given some window's selection")
    func agentRefused() async throws {
        let (app, _) = try makeApp()
        let result = await dispatch("selection.setActions", on: app, caller: .agent, payload: #"{"actions":[]}"#)
        guard case let .failure(error) = result else { Issue.record("expected failure"); return }
        #expect(error.code == BridgeError.notFound)
    }

    @Test("a backend without a selection menu says so instead of showing nothing")
    func unimplementedBackend() async throws {
        let (app, win) = try makeApp()
        (win.webView as! MockWebView).stubbedSelection = nil
        let result = await dispatch("selection.setActions", on: app, caller: .page(win.id), payload: #"{"actions":[]}"#)
        guard case let .failure(error) = result else { Issue.record("expected failure"); return }
        #expect(error.code == BridgeError.unimplemented)
    }

    @Test("bridge.js reports mouse gestures on the command the plugin registers")
    func bridgeScriptUsesPluginCommand() throws {
        let bridge = try BridgeScript.source()
        #expect(bridge.contains("\"\(SelectionPlugin.pointerGestureCommand)\""))
    }
}
