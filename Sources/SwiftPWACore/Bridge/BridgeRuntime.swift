import Foundation

/// Glues a `WebView`'s inbound frame stream to the `CommandRegistry`
/// and pushes results back out via `webView.deliver`.
///
/// Each window owns one `BridgeRuntime` instance, kept alive as long
/// as the window is alive.
///
/// **Threading**: this class is *not* `@MainActor`. The pump task
/// runs on the cooperative pool and dispatches command handlers
/// (which are non-isolated). Backend `PWAWebView.deliver` is
/// responsible for hopping to the platform UI thread internally.
/// (The previous `@MainActor` design hung on Linux because Swift's
/// MainActor executor isn't pumped by `gtk_main()`.)
public final class BridgeRuntime: @unchecked Sendable {
    private let webView: any PWAWebView
    private let registry: CommandRegistry
    private let windowID: WindowID
    private weak var app: AnyObject?
    private let lock = NSLock()
    private var pumpTask: Task<Void, Never>?
    private var subscriptions: [UInt64: Task<Void, Never>] = [:]
    /// Inbound sinks for open duplex sessions (see `registerSession`). One is
    /// created per `subscribe` (before dispatch, so a `push` that the serial
    /// pump handles next always finds it); plain-stream handlers simply never
    /// read theirs. `push` frames route here; teardown finishes it. Each sink
    /// pairs the bounded continuation with a drop counter incremented when the
    /// buffer overflows (drop-oldest), surfaced to the handler as
    /// `BridgeInbound.droppedCount`.
    private var sessionInbound: [UInt64: SessionSink] = [:]

    /// Default bound on buffered client frames per session when a
    /// `registerSession` command doesn't specify one — drops oldest on overflow
    /// so a flooding client can't grow memory unboundedly.
    static let defaultSessionInboundBuffer = 256

    private struct SessionSink {
        let continuation: AsyncStream<Data>.Continuation
        let drops: DropCounter
    }

    public init(
        webView: any PWAWebView,
        registry: CommandRegistry,
        windowID: WindowID,
        app: any AppContext
    ) {
        self.webView = webView
        self.registry = registry
        self.windowID = windowID
        self.app = app as AnyObject
    }

    /// Begin pumping inbound frames from the webview into the registry.
    /// Idempotent — calling twice is a no-op.
    public func start() {
        let stream = webView.inboundFrames()
        lock.withLock {
            guard pumpTask == nil else { return }
            pumpTask = Task { [weak self] in
                for await frame in stream {
                    guard let self else { return }
                    await handle(frame)
                }
            }
        }
    }

    public func stop() {
        let (oldPump, oldSubs, oldInbound) = lock.withLock {
            let p = pumpTask
            let s = subscriptions
            let i = sessionInbound
            pumpTask = nil
            subscriptions.removeAll()
            sessionInbound.removeAll()
            return (p, s, i)
        }
        oldPump?.cancel()
        for (_, task) in oldSubs { task.cancel() }
        for (_, sink) in oldInbound { sink.continuation.finish() }
    }

    /// Test hook: returns whether a streaming subscription is currently
    /// active for the given correlation id.
    public func hasActiveSubscription(id: UInt64) -> Bool {
        lock.withLock { subscriptions[id] != nil }
    }

    deinit {
        let (oldPump, oldSubs, oldInbound) = lock.withLock {
            (pumpTask, subscriptions, sessionInbound)
        }
        oldPump?.cancel()
        for (_, task) in oldSubs { task.cancel() }
        for (_, sink) in oldInbound { sink.continuation.finish() }
    }

    // MARK: - private

    private func handle(_ frame: InboundFrame) async {
        switch frame {
        case let .invoke(id, command, payload):
            await dispatchInvoke(id: id, command: command, payload: payload)
        case let .subscribe(id, command, payload):
            await dispatchSubscribe(id: id, command: command, payload: payload)
        case let .unsubscribe(id):
            removeSubscription(id)
        case let .push(id, payload):
            routePush(id: id, payload: payload)
        }
    }

    /// Route a client-pushed frame into its open session's inbound stream.
    /// A `push` for an unknown id (session already closed, or the target was
    /// a plain non-session stream that finished) is silently dropped. If the
    /// bounded buffer is full, the oldest frame is dropped and the session's
    /// drop counter is bumped (surfaced as `BridgeInbound.droppedCount`).
    private func routePush(id: UInt64, payload: Data) {
        let sink = lock.withLock { sessionInbound[id] }
        guard let sink else { return }
        if case .dropped = sink.continuation.yield(payload) { sink.drops.increment() }
    }

    private func dispatchInvoke(id: UInt64, command: String, payload: Data) async {
        guard let app = app as? any AppContext else { return }
        let inv = Invocation(id: id, command: command, payload: payload)
        let context = CommandContext(invocation: inv, originWindow: windowID, appContext: app)
        let result = await registry.dispatch(context)
        await deliver(result, id: id)
    }

    private func dispatchSubscribe(id: UInt64, command: String, payload: Data) async {
        guard let app = app as? any AppContext else { return }
        let inv = Invocation(id: id, command: command, payload: payload)

        // Create the session inbound stream + continuation *before* dispatch and
        // store it synchronously, so a `push` frame the serial pump handles next
        // always finds a live sink (see `sessionInbound`). Plain-stream handlers
        // just never read `context.sessionInbound`; the continuation is finished
        // on completion/teardown either way. The bound is per-command
        // (`registerSession(maxBufferedFrames:)`), looked up by name here since
        // the handler closure that carries it doesn't run until dispatch.
        let bound = registry.sessionBufferBound(for: command) ?? Self.defaultSessionInboundBuffer
        let (inbound, inboundContinuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingNewest(bound)
        )
        let drops = DropCounter()
        lock.withLock { sessionInbound[id] = SessionSink(continuation: inboundContinuation, drops: drops) }

        let context = CommandContext(
            invocation: inv,
            originWindow: windowID,
            appContext: app,
            sessionInbound: SessionInbound(frames: inbound, droppedCount: { drops.value })
        )
        let result = await registry.dispatch(context)
        switch result {
        case let .ok(data):
            try? await webView.deliver(.event(id: id, chunk: data))
            try? await webView.deliver(.end(id: id))
            finishInbound(id)
        case let .failure(err):
            try? await webView.deliver(.replyError(id: id, error: err))
            finishInbound(id)
        case let .stream(stream):
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await chunk in stream {
                        if Task.isCancelled { break }
                        try await webView.deliver(.event(id: id, chunk: chunk))
                    }
                    try? await webView.deliver(.end(id: id))
                } catch let err as BridgeError {
                    try? await self.webView.deliver(.replyError(id: id, error: err))
                } catch {
                    try? await webView.deliver(.replyError(
                        id: id,
                        error: BridgeError(code: BridgeError.handler, message: "\(error)")
                    ))
                }
                removeSubscription(id)
            }
            setSubscription(id, task)
        }
    }

    private func deliver(_ result: InvocationResult, id: UInt64) async {
        switch result {
        case let .ok(data):
            try? await webView.deliver(.reply(id: id, ok: data))
        case let .failure(err):
            try? await webView.deliver(.replyError(id: id, error: err))
        case .stream:
            // `invoke` is unary by contract; treat a stream result as an error.
            try? await webView.deliver(.replyError(
                id: id,
                error: BridgeError(
                    code: BridgeError.handler,
                    message: "command returned a stream but was called via invoke()"
                )
            ))
        }
    }

    private func setSubscription(_ id: UInt64, _ task: Task<Void, Never>) {
        lock.withLock { subscriptions[id] = task }
    }

    private func removeSubscription(_ id: UInt64) {
        let (task, sink) = lock.withLock {
            let t = subscriptions[id]
            subscriptions.removeValue(forKey: id)
            let s = sessionInbound[id]
            sessionInbound.removeValue(forKey: id)
            return (t, s)
        }
        task?.cancel()
        sink?.continuation.finish()
    }

    /// Finish + drop a session's inbound stream without cancelling a
    /// subscription task (used on the unary `.ok` / `.failure` subscribe paths,
    /// which have no task to cancel).
    private func finishInbound(_ id: UInt64) {
        let sink = lock.withLock {
            let s = sessionInbound[id]
            sessionInbound.removeValue(forKey: id)
            return s
        }
        sink?.continuation.finish()
    }
}

/// Thread-safe monotonic counter of dropped session-inbound frames. A reference
/// type so `BridgeRuntime` (which increments on buffer overflow) and the
/// handler's `BridgeInbound.droppedCount` observe the same value.
final class DropCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.withLock { count }
    }
    func increment() { lock.withLock { count += 1 } }
}
