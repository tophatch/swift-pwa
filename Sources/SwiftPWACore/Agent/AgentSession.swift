import Foundation

/// Verb dispatch for the agent control socket — the half with no sockets in it,
/// so it unit-tests against a `MockAppContext` without binding a port.
///
/// Two verbs, newline-delimited JSON:
///
/// ```text
/// → {"id":1,"token":"…","cmd":"describe"}
/// ← {"id":1,"ok":true,"result":{"tools":[{"name":"book_open","command":"book.open",…}]}}
/// → {"id":2,"token":"…","cmd":"call","payload":{"name":"book_open","arguments":{"id":"7"}}}
/// ← {"id":2,"ok":true,"result":{…}}
/// ```
///
/// `describe` returns each tool's argument shape as a ``BridgeSchema`` rather
/// than JSON Schema: the lowering is a pure function the CLI already owns, and
/// keeping it out of the runtime means fixing a schema-mapping bug doesn't need
/// an app rebuild.
///
/// **The allowlist is enforced here, in the app.** The relay is an ordinary
/// local process and can't be trusted to filter on the runtime's behalf.
///
/// **Not `@MainActor`** — every dispatch hops through ``MainThread/run``,
/// because under `gtk_main()` Swift's main-actor executor is never drained and
/// a `@MainActor` method awaited from the socket thread would hang on Linux.
final class AgentSession: Sendable {
    /// Bumped when a frame's shape changes incompatibly, so a mismatched relay
    /// can say so rather than failing obscurely.
    static let protocolVersion = 1

    private let surface: AgentSurface

    init(surface: AgentSurface) {
        self.surface = surface
    }

    func handle(line: Data) async -> Data {
        let request: AgentRequest
        do {
            request = try JSONDecoder().decode(AgentRequest.self, from: line)
        } catch {
            return Self.encode(AgentResponse(
                id: nil,
                error: BridgeError(code: BridgeError.invalidEnvelope, message: "not a JSON control frame: \(error)")
            ))
        }

        // Checked against the *live* token, so a `disable()` that raced this
        // frame in refuses it rather than serving one last call.
        guard let token = surface.currentToken, request.token == token else {
            return Self.encode(AgentResponse(
                id: request.id,
                error: BridgeError(code: AgentError.auth, message: "agent access is off, or the token is wrong")
            ))
        }

        do {
            return try await Self.encode(AgentResponse(id: request.id, result: dispatch(request)))
        } catch let error as BridgeError {
            return Self.encode(AgentResponse(id: request.id, error: error))
        } catch {
            return Self.encode(AgentResponse(
                id: request.id,
                error: BridgeError(code: BridgeError.handler, message: "\(error)")
            ))
        }
    }

    private func dispatch(_ request: AgentRequest) async throws -> JSONValue {
        switch request.cmd {
        case "describe":
            return await describe()
        case "call":
            return try await call(request.payload ?? .object([:]))
        default:
            throw BridgeError(
                code: AgentError.command,
                message: "unknown verb '\(request.cmd)'. This build serves: describe, call."
            )
        }
    }

    // MARK: - describe

    private func describe() async -> JSONValue {
        guard let context = surface.appContext else {
            return .object(["protocolVersion": .number(Double(Self.protocolVersion)), "tools": .array([])])
        }
        // Cross the declared ceiling with what's actually registered: a tool
        // whose command has since disappeared is dropped rather than advertised
        // as callable. The build-time check makes this rare, but a dynamically
        // registered command can still be absent at runtime.
        let registered = await MainThread.run { context.registry.descriptors() }
        let descriptors = Dictionary(
            registered.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let tools: [JSONValue] = surface.tools.compactMap { tool in
            guard let descriptor = descriptors[tool.command], descriptor.kind == .unary else { return nil }
            var fields: [String: JSONValue] = [
                "name": .string(tool.resolvedToolName),
                "command": .string(tool.command),
                "description": .string(tool.description)
            ]
            if let args = try? JSONValue.decode(JSONEncoder().encode(descriptor.args)) {
                fields["args"] = args
            }
            var annotations: [String: JSONValue] = [:]
            if let value = tool.readOnly { annotations["readOnlyHint"] = .bool(value) }
            if let value = tool.destructive { annotations["destructiveHint"] = .bool(value) }
            if let value = tool.idempotent { annotations["idempotentHint"] = .bool(value) }
            if let value = tool.openWorld { annotations["openWorldHint"] = .bool(value) }
            if !annotations.isEmpty { fields["annotations"] = .object(annotations) }
            return .object(fields)
        }

        return .object([
            "protocolVersion": .number(Double(Self.protocolVersion)),
            "tools": .array(tools)
        ])
    }

    // MARK: - call

    private func call(_ payload: JSONValue) async throws -> JSONValue {
        guard case let .string(name)? = payload["name"] else {
            throw BridgeError(code: AgentError.request, message: "call needs a tool 'name'")
        }
        // By tool name, not command name: the agent only ever knew the tool
        // name, and accepting a raw command here would be a way around the
        // allowlist for anything that guessed one.
        guard let tool = surface.tools.first(where: { $0.resolvedToolName == name }) else {
            throw BridgeError(
                code: AgentError.notAllowed,
                message: "'\(name)' is not one of this app's exposed tools"
            )
        }
        guard let context = surface.appContext else {
            throw BridgeError(code: AgentError.command, message: "the app isn't ready to serve tool calls")
        }

        let arguments = payload["arguments"] ?? .object([:])
        let invocation = try Invocation(
            id: 0,
            command: tool.command,
            payload: arguments.encoded()
        )

        // `AppContext` is MainActor-isolated, so the context object is read on
        // the UI thread; `CommandRegistry.dispatch` is not, and runs here.
        let registry = await MainThread.run { context.registry }
        let command = await MainThread.run {
            CommandContext(invocation: invocation, originWindow: nil, appContext: context)
        }
        switch await registry.dispatch(command) {
        case let .ok(data):
            return (try? JSONValue.decode(data)) ?? .null
        case let .failure(error):
            throw error
        case .stream:
            // Unreachable via the allowlist (only unary commands are described),
            // but a command re-registered as a stream at runtime would land here.
            throw BridgeError(
                code: AgentError.notAllowed,
                message: "'\(name)' streams, and a tool call is one request and one result"
            )
        }
    }

    // MARK: - Wire types

    private static func encode(_ response: AgentResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data("{\"ok\":false}".utf8)
    }
}

/// Error codes on the agent channel. Distinct from the driver's so a relay can
/// tell "you're not allowed to call that" from "that isn't a verb".
enum AgentError {
    static let auth = "E_AGENT_AUTH"
    static let request = "E_AGENT_REQUEST"
    static let command = "E_AGENT_COMMAND"
    static let notAllowed = "E_AGENT_NOT_ALLOWED"
}

struct AgentRequest: Decodable {
    let id: UInt64?
    let token: String
    let cmd: String
    let payload: JSONValue?
}

struct AgentResponse: Encodable {
    let id: UInt64?
    var ok: Bool {
        error == nil
    }
    var result: JSONValue?
    var error: BridgeError?

    init(id: UInt64?, result: JSONValue) {
        self.id = id
        self.result = result
        error = nil
    }

    init(id: UInt64?, error: BridgeError) {
        self.id = id
        result = nil
        self.error = error
    }

    private enum CodingKeys: String, CodingKey { case id, ok, result, error }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(ok, forKey: .ok)
        try c.encodeIfPresent(result, forKey: .result)
        try c.encodeIfPresent(error, forKey: .error)
    }
}
