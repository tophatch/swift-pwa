import Foundation

/// Exposes `agent.*` to the app's own page, so it can draw a consent UI.
///
/// Opt-in: install it with the tool list the app is willing to offer. Nothing
/// is exposed until the *user* calls `agent.enable` from that UI.
///
/// ```swift
/// ctx.use(AgentPlugin(tools: [
///     AgentTool(command: "book.open", description: "Open a book by id.", readOnly: true)
/// ]))
/// ```
///
/// `swift-pwa init` seeds this call from `pwa.json`'s `agent.expose`, and
/// `swift-pwa build` fails if the two drift apart — `pwa.json` stays the
/// reviewable declaration while the compiled list is what's enforced.
///
/// The commands here are for the *app*, not for an agent: `agent.` is a
/// refused prefix in the allowlist, because a tool that could call
/// `agent.enable` would be able to widen its own access.
public struct AgentPlugin: Plugin {
    public static let pluginName = "agent"

    private let surface: AgentSurface

    public init(tools: [AgentTool]) {
        surface = AgentSurface(tools: tools)
    }

    /// For an app that wants to hold the surface itself — to reflect state in
    /// native UI, or to revoke on some app event.
    public init(surface: AgentSurface) {
        self.surface = surface
    }

    public var agentSurface: AgentSurface {
        surface
    }

    public func register(into registry: CommandRegistry, app: any AppContext) {
        let surface = surface
        surface.install(context: app, indicator: AgentIndicator.installed)

        registry.register(
            "agent.status",
            typed: { (_: EmptyArgs, _) async throws -> AgentState in
                surface.state
            }
        )

        registry.register(
            "agent.enable",
            typed: { (_: EmptyArgs, _) async throws -> AgentState in
                do {
                    return try surface.enable()
                } catch {
                    throw BridgeError(code: "E_AGENT", message: "couldn't open the agent channel: \(error)")
                }
            }
        )

        registry.register(
            "agent.disable",
            typed: { (_: EmptyArgs, _) async throws -> AgentState in
                surface.disable()
                return surface.state
            }
        )

        // A stream rather than polling: the interesting transitions (a client
        // attaching, a client dropping) originate in the runtime, not in the
        // page, so a consent UI that had to poll would show stale state exactly
        // when it matters most.
        registry.registerStream(
            "agent.state",
            typed: { (_: EmptyArgs, _) -> AsyncThrowingStream<AgentState, any Error> in
                AsyncThrowingStream { continuation in
                    let observation = surface.observe { state in
                        continuation.yield(state)
                    }
                    continuation.onTermination = { _ in
                        observation.cancel()
                    }
                }
            }
        )
    }
}

/// Where a backend installs its user-visible "an agent is attached" indicator.
///
/// This is a process-global hook rather than something the app passes in, and
/// deliberately so: an app that could supply or replace the indicator could
/// also suppress it, and the one thing that has to survive a developer cutting
/// corners is that the user can *see* an agent is connected.
///
/// The same shape as ``MainThread``'s dispatch hook — Core declares it, the
/// platform backend installs one at startup.
public enum AgentIndicator {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var hook: (@Sendable (AgentState) -> Void)?

    /// Called once by a backend during startup.
    public static func install(_ hook: @escaping @Sendable (AgentState) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.hook = hook
    }

    static var installed: (@Sendable (AgentState) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return hook
    }
}
