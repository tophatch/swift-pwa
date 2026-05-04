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
        let (oldPump, oldSubs) = lock.withLock {
            let p = pumpTask
            let s = subscriptions
            pumpTask = nil
            subscriptions.removeAll()
            return (p, s)
        }
        oldPump?.cancel()
        for (_, task) in oldSubs { task.cancel() }
    }

    /// Test hook: returns whether a streaming subscription is currently
    /// active for the given correlation id.
    public func hasActiveSubscription(id: UInt64) -> Bool {
        lock.withLock { subscriptions[id] != nil }
    }

    deinit {
        let (oldPump, oldSubs) = lock.withLock {
            (pumpTask, subscriptions)
        }
        oldPump?.cancel()
        for (_, task) in oldSubs { task.cancel() }
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
        }
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
        let context = CommandContext(invocation: inv, originWindow: windowID, appContext: app)
        let result = await registry.dispatch(context)
        switch result {
        case let .ok(data):
            try? await webView.deliver(.event(id: id, chunk: data))
            try? await webView.deliver(.end(id: id))
        case let .failure(err):
            try? await webView.deliver(.replyError(id: id, error: err))
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
        let task = lock.withLock {
            let t = subscriptions[id]
            subscriptions.removeValue(forKey: id)
            return t
        }
        task?.cancel()
    }
}
