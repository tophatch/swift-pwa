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

/// One state change, plus the ability to act on it.
public struct AgentIndicatorUpdate: Sendable {
    public let state: AgentState
    /// Revoke access. The indicator is also the place a user can turn it off,
    /// which matters when the app's own window isn't in front of them.
    public let disable: @Sendable () -> Void
}

/// Where a backend installs its user-visible "agent access is open" indicator.
///
/// A process-global hook rather than something the app passes in, and
/// deliberately so: an app that could supply or replace the indicator could
/// also suppress it, and the one thing that has to survive a developer cutting
/// corners is that the user can *see* the door is open.
///
/// The same shape as ``MainThread``'s dispatch hook — Core declares it, the
/// platform backend installs one at startup.
public enum AgentIndicator {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var hook: (@Sendable (AgentIndicatorUpdate) -> Void)?

    /// Called once by a backend during startup.
    public static func install(_ hook: @escaping @Sendable (AgentIndicatorUpdate) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.hook = hook
    }

    /// The standard indicator for a backend with a system tray: a status item
    /// that appears while agent access is open and disappears when it closes,
    /// with a menu to turn it off.
    ///
    /// The *behaviour* lives here rather than in each backend so there's one
    /// definition of what the user sees, and so it can't be quietly varied per
    /// platform. Backends supply only a tray.
    ///
    /// Shown from the moment access is **enabled**, not from the moment a
    /// client connects: the port is open and anyone holding the token can
    /// connect, so a user who forgot they'd allowed it would otherwise see
    /// nothing at all.
    public static func installTray(_ makeTray: @escaping @MainActor @Sendable () -> any Tray) {
        let holder = TrayIndicatorHolder(makeTray: makeTray)
        install { update in
            Task { await MainThread.run { holder.apply(update) } }
        }
    }

    static var installed: (@Sendable (AgentIndicatorUpdate) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return hook
    }
}
