import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

/// The user's gate on the agent tool surface: off at launch, per-session,
/// revocable — and the allowlist enforced in the app rather than in whatever
/// relay is talking to it.
@Suite("Agent surface")
struct AgentSurfaceTests {
    static let tools = [
        AgentTool(command: "book.open", description: "Open a book.", readOnly: true),
        AgentTool(command: "book.delete", description: "Delete a book.", destructive: true),
        AgentTool(command: "book.rename", description: "Rename a book.", toolName: "rename")
    ]

    // MARK: - Naming

    @Test("a tool name derives from the command, dots to underscores")
    func derivesToolNames() {
        #expect(AgentTool(command: "book.open", description: "x").resolvedToolName == "book_open")
        #expect(AgentTool(command: "now", description: "x").resolvedToolName == "now")
    }

    @Test("an explicit tool name wins")
    func explicitToolName() {
        #expect(Self.tools[2].resolvedToolName == "rename")
    }

    // MARK: - The gate

    @Test("a freshly built surface is off, with no port and no token")
    func offAtLaunch() {
        let surface = AgentSurface(tools: Self.tools)
        let state = surface.state
        #expect(state.enabled == false)
        #expect(state.attached == false)
        #expect(state.port == nil)
        #expect(state.token == nil)
        // The ceiling is readable while off — that's what a consent UI needs to
        // describe what it's asking for.
        #expect(state.tools.count == 3)
    }

    @Test("enable binds a port and mints a token; disable gives both back")
    func enableThenDisable() throws {
        let surface = AgentSurface(tools: Self.tools)
        let state = try surface.enable()
        #expect(state.enabled)
        #expect((state.port ?? 0) > 0)
        #expect(state.token?.count == 32) // 128 bits, hex

        surface.disable()
        #expect(surface.state.enabled == false)
        #expect(surface.state.token == nil)
    }

    @Test("enabling twice keeps the same token")
    func enableIsIdempotent() throws {
        let surface = AgentSurface(tools: Self.tools)
        let first = try surface.enable()
        let second = try surface.enable()
        // A consent UI that re-renders shouldn't invalidate a connection the
        // user already configured.
        #expect(first.token == second.token)
        #expect(first.port == second.port)
        surface.disable()
    }

    @Test("re-enabling after a revoke mints a new token")
    func revokeRotatesTheToken() throws {
        let surface = AgentSurface(tools: Self.tools)
        let first = try surface.enable()
        surface.disable()
        let second = try surface.enable()
        // A token someone noted down shouldn't outlive the session it was for.
        #expect(first.token != second.token)
        surface.disable()
    }

    @Test("an observer sees the current state immediately, then each change")
    func observersSeeState() throws {
        let surface = AgentSurface(tools: Self.tools)
        let states = StateRecorder()
        let observation = surface.observe { states.append($0) }
        #expect(states.count == 1)
        #expect(states.last?.enabled == false)

        try surface.enable()
        #expect(states.last?.enabled == true)
        surface.disable()
        #expect(states.last?.enabled == false)
        observation.cancel()

        let before = states.count
        try surface.enable()
        #expect(states.count == before) // cancelled
        surface.disable()
    }

    // MARK: - Session dispatch

    @Test("a frame without the current token is refused")
    func tokenIsRequired() async throws {
        let surface = AgentSurface(tools: Self.tools)
        try surface.enable()
        defer { surface.disable() }
        let session = AgentSession(surface: surface)

        let response = try await Self.decode(session.handle(line: Self.frame(token: "nope", cmd: "describe")))
        #expect(response["ok"] == .bool(false))
        #expect(response["error"]?["code"] == .string("E_AGENT_AUTH"))
    }

    @Test("every frame is refused while the surface is off")
    func refusedWhileDisabled() async throws {
        let surface = AgentSurface(tools: Self.tools)
        let token = try surface.enable().token ?? ""
        surface.disable()
        let session = AgentSession(surface: surface)

        // Even the token that *was* valid: revocation means now, and a frame
        // that raced the disable in shouldn't get one last call.
        let response = try await Self.decode(session.handle(line: Self.frame(token: token, cmd: "describe")))
        #expect(response["error"]?["code"] == .string("E_AGENT_AUTH"))
    }

    @Test("an unknown verb says what the channel does serve")
    func unknownVerb() async throws {
        let surface = AgentSurface(tools: Self.tools)
        let token = try surface.enable().token ?? ""
        defer { surface.disable() }
        let session = AgentSession(surface: surface)

        let response = try await Self.decode(session.handle(line: Self.frame(token: token, cmd: "eval")))
        #expect(response["error"]?["code"] == .string("E_AGENT_COMMAND"))
        #expect(response["error"]?["message"]?.stringDescription.contains("describe") == true)
    }

    @Test("a tool that isn't on the list is refused, not dispatched")
    func undeclaredToolIsRefused() async throws {
        let app = await MockAppContext()
        await app.registry.register("secret.exfiltrate", typed: { (_: EmptyArgs, _) -> EmptyResult in
            Issue.record("an undeclared command must never be dispatched")
            return EmptyResult()
        })
        let surface = AgentSurface(tools: Self.tools)
        surface.install(context: app, indicator: nil)
        let token = try surface.enable().token ?? ""
        defer { surface.disable() }
        let session = AgentSession(surface: surface)

        for name in ["secret.exfiltrate", "secret_exfiltrate"] {
            let response = try await Self.decode(session.handle(
                line: Self.frame(token: token, cmd: "call", payload: ["name": .string(name)])
            ))
            #expect(response["error"]?["code"] == .string("E_AGENT_NOT_ALLOWED"), "\(name) was not refused")
        }
    }

    @Test("a declared tool is dispatched, and its result comes back")
    func declaredToolRuns() async throws {
        let app = await MockAppContext()
        await app.registry.register("book.open", typed: { (args: OpenArgs, _) -> OpenResult in
            OpenResult(title: "book \(args.id)")
        })
        let surface = AgentSurface(tools: Self.tools)
        surface.install(context: app, indicator: nil)
        let token = try surface.enable().token ?? ""
        defer { surface.disable() }
        let session = AgentSession(surface: surface)

        let response = try await Self.decode(session.handle(line: Self.frame(
            token: token, cmd: "call",
            payload: ["name": .string("book_open"), "arguments": .object(["id": .string("7")])]
        )))
        #expect(response["ok"] == .bool(true))
        #expect(response["result"]?["title"] == .string("book 7"))
    }

    @Test("describe reports only declared tools that are really registered")
    func describeCrossesTheCatalog() async throws {
        let app = await MockAppContext()
        await app.registry.register("book.open", typed: { (_: OpenArgs, _) -> OpenResult in OpenResult(title: "x") })
        // `book.delete` and `book.rename` are declared but never registered.
        let surface = AgentSurface(tools: Self.tools)
        surface.install(context: app, indicator: nil)
        let token = try surface.enable().token ?? ""
        defer { surface.disable() }
        let session = AgentSession(surface: surface)

        let response = try await Self.decode(session.handle(line: Self.frame(token: token, cmd: "describe")))
        guard case let .array(tools)? = response["result"]?["tools"] else {
            Issue.record("no tools array: \(response)")
            return
        }
        #expect(tools.count == 1)
        #expect(tools.first?["name"] == .string("book_open"))
        #expect(tools.first?["annotations"]?["readOnlyHint"] == .bool(true))
        #expect(tools.first?["args"] != nil)
    }

    // MARK: - Fixtures

    struct OpenArgs: Codable { let id: String }
    struct OpenResult: Codable { let title: String }

    /// Collects observer callbacks, which arrive on whichever thread published.
    final class StateRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [AgentState] = []

        func append(_ state: AgentState) {
            lock.lock()
            states.append(state)
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return states.count
        }

        var last: AgentState? {
            lock.lock()
            defer { lock.unlock() }
            return states.last
        }
    }

    static func frame(token: String, cmd: String, payload: [String: JSONValue]? = nil) -> Data {
        var fields: [String: JSONValue] = ["id": .number(1), "token": .string(token), "cmd": .string(cmd)]
        if let payload { fields["payload"] = .object(payload) }
        return (try? JSONValue.object(fields).encoded()) ?? Data()
    }

    static func decode(_ data: Data) throws -> JSONValue {
        try JSONValue.decode(data)
    }
}

private extension JSONValue {
    subscript(key: String) -> JSONValue? {
        guard case let .object(fields) = self else { return nil }
        return fields[key]
    }

    var stringDescription: String {
        guard case let .string(value) = self else { return "" }
        return value
    }
}
