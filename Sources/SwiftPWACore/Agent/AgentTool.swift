import Foundation

/// One command the app is willing to offer an AI agent, as the app declares it.
///
/// This is the compiled counterpart of a `pwa.json` `agent.expose` entry, and
/// the two are checked against each other at build time — `pwa.json` is the
/// reviewable declaration, the compiled list is what the runtime enforces, and
/// drift between them fails the build rather than quietly changing what an app
/// offers.
///
/// Declaring a tool exposes nothing on its own. It sets the *ceiling*: the
/// user still has to turn exposure on at runtime, per session. See
/// ``AgentSurface``.
public struct AgentTool: Codable, Sendable, Equatable {
    /// The registered command this tool calls.
    public let command: String
    /// What it does, in one line — what an agent reads to decide whether to
    /// call it.
    public let description: String
    /// Only reads state. Surfaces as MCP's `readOnlyHint`.
    public let readOnly: Bool?
    /// Can destroy or overwrite something the user cares about. MCP's
    /// `destructiveHint`.
    public let destructive: Bool?
    /// Calling it twice is the same as calling it once. MCP's `idempotentHint`.
    public let idempotent: Bool?
    /// Touches the network or other people's data. MCP's `openWorldHint`.
    public let openWorld: Bool?
    /// Override for the agent-facing name, which otherwise derives from the
    /// command (`book.open` → `book_open`).
    public let toolName: String?

    public init(
        command: String,
        description: String,
        readOnly: Bool? = nil,
        destructive: Bool? = nil,
        idempotent: Bool? = nil,
        openWorld: Bool? = nil,
        toolName: String? = nil
    ) {
        self.command = command
        self.description = description
        self.readOnly = readOnly
        self.destructive = destructive
        self.idempotent = idempotent
        self.openWorld = openWorld
        self.toolName = toolName
    }

    /// The name an agent calls this by. Dots are the bridge's namespace
    /// separator and aren't in MCP's conventional name character set.
    public var resolvedToolName: String {
        toolName ?? String(command.map { $0 == "." ? "_" : $0 })
    }
}

/// What the app tells its own consent UI, and what the runtime reports on the
/// control socket. Deliberately includes the risk counts: a sheet that can say
/// "4 read-only tools, 1 that can delete" is asking a question someone can
/// answer, where "allow agent access?" is not.
public struct AgentState: Codable, Sendable, Equatable {
    /// Whether the user has turned exposure on for this session.
    public let enabled: Bool
    /// Whether a client is connected right now.
    public let attached: Bool
    /// Where to connect, when enabled. `nil` while off.
    public let port: UInt16?
    /// Per-session token, when enabled. The app shows this to the user to
    /// paste into an agent host's configuration.
    public let token: String?
    /// The declared ceiling — every tool that *could* be exposed, whether or
    /// not exposure is currently on.
    public let tools: [AgentTool]

    public init(
        enabled: Bool,
        attached: Bool,
        port: UInt16?,
        token: String?,
        tools: [AgentTool]
    ) {
        self.enabled = enabled
        self.attached = attached
        self.port = port
        self.token = token
        self.tools = tools
    }
}
