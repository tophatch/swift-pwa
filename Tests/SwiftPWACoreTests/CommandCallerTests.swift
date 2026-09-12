import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

/// `CommandContext.caller` is the signal an app needs to answer an agent more
/// narrowly than it answers its own page. It replaced reading `originWindow ==
/// nil`, which happened to work and would have failed *open* the moment the
/// runtime gave an agent call a window id — so the tests that matter are the
/// ones that pin the two dispatch paths to the two cases.
@Suite("Command caller")
struct CommandCallerTests {
    /// The reporting adopter's shape: one command, answering a page in full and
    /// an agent without the private rows.
    static func registerScopedList(on app: MockAppContext) async {
        await app.registry.register("stories.list", typed: { (_: EmptyArgs, ctx) -> ListResult in
            switch ctx.caller {
            case .page: ListResult(titles: ["public", "locked"])
            case .agent: ListResult(titles: ["public"])
            }
        })
    }

    @Test("an agent tool call arrives as .agent, and a scoped handler narrows")
    func agentCallIsAgent() async throws {
        let app = await MockAppContext()
        await Self.registerScopedList(on: app)
        let surface = AgentSurface(tools: [AgentTool(command: "stories.list", description: "List.", readOnly: true)])
        surface.install(context: app, indicator: nil)
        let token = try surface.enable().token ?? ""
        defer { surface.disable() }

        let session = AgentSession(surface: surface)
        let response = try await JSONValue.decode(session.handle(line: AgentSurfaceTests.frame(
            token: token, cmd: "call", payload: ["name": .string("stories_list")]
        )))

        #expect(response["ok"] == .bool(true))
        #expect(response["result"]?["titles"] == .array([.string("public")]))
    }

    @Test("a page invoke arrives as .page with that window's id, and sees everything")
    @MainActor
    func pageInvokeIsPage() async throws {
        let app = MockAppContext()
        await Self.registerScopedList(on: app)
        let webView = MockWebView()
        let win = MockWindow(webView: webView)
        app.attach(win)
        let bridge = BridgeRuntime(webView: webView, registry: app.registry, windowID: win.id, app: app)
        bridge.start()
        defer { bridge.stop() }

        // The caller the handler actually saw, recorded from inside dispatch —
        // the reply alone can't tell `.page(a)` from `.page(b)`.
        let seen = CallerBox()
        await app.registry.register("probe.caller", typed: { (_: EmptyArgs, ctx) -> EmptyResult in
            seen.value = ctx.caller
            return EmptyResult()
        })

        try webView.sendInvoke(id: 1, command: "stories.list", payload: EmptyArgs())
        try webView.sendInvoke(id: 2, command: "probe.caller", payload: EmptyArgs())
        try await waitFor { seen.value != nil }

        #expect(seen.value == .page(win.id))
        guard case let .reply(_, data, _)? = webView.deliveredFrames.first(where: {
            if case let .reply(id, _, _) = $0 { id == 1 } else { false }
        }) else {
            Issue.record("no reply for the page's stories.list")
            return
        }
        #expect(try JSONDecoder().decode(ListResult.self, from: data).titles == ["public", "locked"])
    }

    @Test("originWindow is derived from caller, so the two can't disagree")
    func originWindowTracksCaller() async {
        let app = await MockAppContext()
        let invocation = Invocation(id: 0, command: "x", payload: Data())
        let id = WindowID(raw: "w1")
        #expect(CommandContext(invocation: invocation, caller: .page(id), appContext: app).originWindow == id)
        #expect(CommandContext(invocation: invocation, caller: .agent, appContext: app).originWindow == nil)
    }

    struct ListResult: Codable { let titles: [String] }

    /// The handler runs on the cooperative pool; the test reads after it.
    final class CallerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CommandCaller?
        var value: CommandCaller? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
