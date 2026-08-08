import Foundation

/// The runtime half of the agent-tool surface: the user's gate.
///
/// The developer's gate is the declared tool list (compiled in, checked against
/// `pwa.json` at build time). This is the other one — whether anything is
/// exposed *right now*:
///
/// - **Off at launch**, always. There is no configuration key that makes an app
///   exposed from startup; something has to call ``enable()``.
/// - **Per session.** Nothing is persisted, so a relaunch is off again. A
///   user who allowed an agent once hasn't allowed it forever.
/// - **Revocable.** ``disable()`` closes the listener *and drops a connected
///   client*, because a user who turns access off means now, not next time.
/// - **Token per enable.** A fresh token each time, so a token someone noted
///   down doesn't outlive the session it was for.
///
/// ## What this can't do
///
/// It can't enforce consent. The app is native code, and a developer who wants
/// to call `enable()` at launch will. Anything framed as enforcement here would
/// be theatre. What it does instead is make the honest path the easy one and
/// the dishonest one visible: swift-pwa owns the state and the user-visible
/// indicator, and the app owns the asking — its own consent UI, because it
/// knows its own vocabulary and a swift-pwa-drawn dialog would look foreign
/// across five platforms at once.
///
/// **Not `@MainActor`**: attach / detach callbacks arrive on the socket's
/// accept thread. State is guarded by a lock (the ``CommandRegistry`` pattern),
/// and anything touching UI hops through ``MainThread/run``.
public final class AgentSurface: @unchecked Sendable {
    /// Every tool the app declared — the ceiling. Fixed at construction.
    public let tools: [AgentTool]

    private let lock = NSLock()
    private var server: LoopbackServer?
    private var token: String?
    private var attachedCount = 0
    private var observers: [UUID: @Sendable (AgentState) -> Void] = [:]
    private weak var context: (any AppContext)?

    /// Called with each state change so a backend can show or hide its
    /// indicator. Set once at install; not part of the app-facing API, since an
    /// app that could replace it could hide the fact that it's attached.
    private var indicator: (@Sendable (AgentIndicatorUpdate) -> Void)?

    public init(tools: [AgentTool]) {
        self.tools = tools
    }

    // MARK: - State

    public var state: AgentState {
        lock.lock()
        defer { lock.unlock() }
        return unlockedState()
    }

    private func unlockedState() -> AgentState {
        AgentState(
            enabled: server != nil,
            attached: attachedCount > 0,
            port: server?.port,
            token: token,
            tools: tools
        )
    }

    // MARK: - The gate

    /// Turn exposure on for this session, binding a loopback listener and
    /// minting a token.
    ///
    /// Idempotent: calling it while already enabled returns the existing port
    /// and token rather than rotating them, so a consent UI that re-renders
    /// doesn't invalidate a connection the user already set up.
    @discardableResult
    public func enable() throws -> AgentState {
        lock.lock()
        if server != nil {
            defer { lock.unlock() }
            return unlockedState()
        }
        lock.unlock()

        let token = LoopbackServer.makeToken()
        // Port 0: the OS picks. A fixed port would collide between two swift-pwa
        // apps, and the user is copying the number into a host config anyway.
        let server = try LoopbackServer.start(
            port: 0,
            onAttach: { [weak self] in self?.clientAttached() },
            onDetach: { [weak self] in self?.clientDetached() },
            handler: { [weak self] line in
                guard let self else { return Data("{\"ok\":false}".utf8) }
                return await session.handle(line: line)
            }
        )

        lock.lock()
        self.server = server
        self.token = token
        let state = unlockedState()
        lock.unlock()

        publish(state)
        return state
    }

    /// Turn exposure off: stop listening and drop anyone connected.
    public func disable() {
        lock.lock()
        let server = server
        self.server = nil
        token = nil
        attachedCount = 0
        let state = unlockedState()
        lock.unlock()

        server?.stop()
        publish(state)
    }

    // MARK: - Wiring (backend-installed)

    /// Attach the live app context and the backend's indicator. Called once by
    /// ``AgentPlugin`` at registration; not public API.
    package func install(context: any AppContext, indicator: (@Sendable (AgentIndicatorUpdate) -> Void)?) {
        lock.lock()
        self.context = context
        self.indicator = indicator
        lock.unlock()
    }

    /// Observe state changes — what `agent.state` streams to the app's consent
    /// UI. Returns a cancel handle.
    package func observe(_ body: @escaping @Sendable (AgentState) -> Void) -> AgentObservation {
        let id = UUID()
        lock.lock()
        observers[id] = body
        let current = unlockedState()
        lock.unlock()
        body(current)
        return AgentObservation { [weak self] in
            guard let self else { return }
            lock.lock()
            observers[id] = nil
            lock.unlock()
        }
    }

    /// The token a request must carry, or `nil` while disabled.
    package var currentToken: String? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    /// The live app context, for routing an allowed call into the registry.
    package var appContext: (any AppContext)? {
        lock.lock()
        defer { lock.unlock() }
        return context
    }

    // MARK: - Internals

    private var session: AgentSession {
        AgentSession(surface: self)
    }

    private func clientAttached() {
        lock.lock()
        attachedCount += 1
        let state = unlockedState()
        lock.unlock()
        publish(state)
    }

    private func clientDetached() {
        lock.lock()
        attachedCount = max(0, attachedCount - 1)
        let state = unlockedState()
        lock.unlock()
        publish(state)
    }

    private func publish(_ state: AgentState) {
        lock.lock()
        let observers = Array(observers.values)
        let indicator = indicator
        lock.unlock()
        for observer in observers { observer(state) }
        // The indicator gets a way to revoke as well as the state: it's often
        // the only agent-access UI in front of the user when the app's own
        // window isn't.
        indicator?(AgentIndicatorUpdate(state: state, disable: { [weak self] in self?.disable() }))
    }
}

/// Cancels an ``AgentSurface/observe(_:)`` registration when released or
/// cancelled explicitly.
package final class AgentObservation: Sendable {
    private let cancelBody: @Sendable () -> Void

    init(_ cancel: @escaping @Sendable () -> Void) {
        cancelBody = cancel
    }

    func cancel() { cancelBody() }
    deinit { cancelBody() }
}
