import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

@Suite("WindowPlugin")
@MainActor
struct WindowPluginTests {
    private func makeApp() async -> (MockAppContext, MockWindow) {
        let app = MockAppContext()
        await app.use(WindowPlugin())
        let win = try! app.createWindow(WindowConfig(
            title: "T",
            size: Size(width: 200, height: 100),
            content: .remote(URL(string: "about:blank")!)
        )) as! MockWindow
        return (app, win)
    }

    @Test("window.setTitle mutates the resolved window")
    func setTitle() async throws {
        let (app, win) = await makeApp()
        let payload = try JSONEncoder().encode(SetTitleArgs(id: nil, title: "renamed"))
        let inv = Invocation(id: 1, command: "window.setTitle", payload: payload)
        let ctx = CommandContext(invocation: inv, originWindow: win.id, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case .ok = result else { Issue.record("expected ok"); return }
        await MainActor.run {
            #expect(win.title() == "renamed")
            #expect(win.receivedActions == [.setTitle("renamed")])
        }
    }

    @Test("window.setSize records both setSize action and didResize event")
    func setSize() async throws {
        let (app, win) = await makeApp()
        let payload = try JSONEncoder().encode(SetSizeArgs(
            id: nil, width: 1024, height: 768, animated: false
        ))
        let inv = Invocation(id: 1, command: "window.setSize", payload: payload)
        let ctx = CommandContext(invocation: inv, originWindow: win.id, appContext: app)
        _ = await app.registry.dispatch(ctx)
        await MainActor.run {
            #expect(win.size() == Size(width: 1024, height: 768))
        }
    }

    @Test("window.id without origin returns notFound")
    func windowIDNoOrigin() async {
        let (app, _) = await makeApp()
        let inv = Invocation(id: 1, command: "window.id", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.code == BridgeError.notFound)
    }

    @Test("window.subscribe streams events emitted by the window")
    func subscribe() async throws {
        let (app, win) = await makeApp()
        let inv = Invocation(id: 1, command: "window.subscribe", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: win.id, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .stream(stream) = result else { Issue.record("expected stream"); return }

        var iterator = stream.makeAsyncIterator()
        await MainActor.run { win.emit(.didFocus) }
        let chunk = try await iterator.next()
        let event = try JSONDecoder().decode(WindowEvent.self, from: #require(chunk))
        #expect(event == .didFocus)

        await MainActor.run { win.emit(.didBlur) }
        let chunk2 = try await iterator.next()
        let event2 = try JSONDecoder().decode(WindowEvent.self, from: #require(chunk2))
        #expect(event2 == .didBlur)
    }

    @Test("window.list returns all live window ids")
    func list() async throws {
        let (app, win) = await makeApp()
        let win2 = try app.createWindow(WindowConfig(
            title: "T2",
            size: Size(width: 100, height: 100),
            content: .remote(#require(URL(string: "about:blank")))
        ))
        let inv = Invocation(id: 1, command: "window.list", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: win.id, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(WindowListResult.self, from: data)
        #expect(Set(out.ids) == [win.id.raw, win2.id.raw])
    }
}
