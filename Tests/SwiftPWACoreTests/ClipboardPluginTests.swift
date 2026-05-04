import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

@Suite("ClipboardPlugin")
@MainActor
struct ClipboardPluginTests {
    private func makeApp(initial: String? = nil) -> (MockAppContext, MockClipboard) {
        let app = MockAppContext()
        let clipboard = MockClipboard(text: initial)
        app.use(ClipboardPlugin(clipboard))
        return (app, clipboard)
    }

    @Test("clipboard.readText returns current contents")
    func readText() async throws {
        let (app, clipboard) = makeApp(initial: "hello")
        let inv = Invocation(id: 1, command: "clipboard.readText", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(ClipboardTextResult.self, from: data)
        #expect(out.text == "hello")
        #expect(clipboard.actions == [.readText])
    }

    @Test("clipboard.readText returns nil when empty")
    func readTextEmpty() async throws {
        let (app, _) = makeApp(initial: nil)
        let inv = Invocation(id: 1, command: "clipboard.readText", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(ClipboardTextResult.self, from: data)
        #expect(out.text == nil)
    }

    @Test("clipboard.writeText replaces contents")
    func writeText() async throws {
        let (app, clipboard) = makeApp(initial: "old")
        let payload = try JSONEncoder().encode(ClipboardWriteTextArgs(text: "new"))
        let inv = Invocation(id: 1, command: "clipboard.writeText", payload: payload)
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case .ok = result else { Issue.record("expected ok"); return }
        #expect(clipboard.text == "new")
        #expect(clipboard.actions == [.writeText("new")])
    }

    @Test("clipboard.clear empties the clipboard")
    func clearText() async {
        let (app, clipboard) = makeApp(initial: "stuff")
        let inv = Invocation(id: 1, command: "clipboard.clear", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case .ok = result else { Issue.record("expected ok"); return }
        #expect(clipboard.text == nil)
        #expect(clipboard.actions == [.clear])
    }

    @Test("ClipboardPlugin reports its own name on install")
    func pluginName() {
        let (app, _) = makeApp()
        #expect(app.installedPlugins.contains("clipboard"))
    }
}
