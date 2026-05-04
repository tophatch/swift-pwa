import Foundation

/// Glues a `WebView`'s inbound frame stream to the `CommandRegistry` and
/// pushes results back out via `webView.deliver`.
///
/// Each window owns one `BridgeRuntime` instance, kept alive as long as
/// the window is alive.
@MainActor
public final class BridgeRuntime {
    private let webView: any PWAWebView
    private let registry: CommandRegistry
    private let windowID: WindowID
    private weak var app: AnyObject?
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
        guard pumpTask == nil else { return }
        let stream = webView.inboundFrames()
        pumpTask = Task { [weak self] in
            for await frame in stream {
                guard let self else { return }
                await self.handle(frame)
            }
        }
    }

    public func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        for (_, task) in subscriptions { task.cancel() }
        subscriptions.removeAll()
    }

    /// Test hook: returns whether a streaming subscription is currently
    /// active for the given correlation id. Used by integration tests
    /// to deterministically wait until the bridge is ready before
    /// emitting events upstream.
    public func hasActiveSubscription(id: UInt64) -> Bool {
        subscriptions[id] != nil
    }

    deinit {
        pumpTask?.cancel()
        for (_, task) in subscriptions { task.cancel() }
    }

    // MARK: - private

    private func handle(_ frame: InboundFrame) async {
        switch frame {
        case .invoke(let id, let command, let payload):
            await dispatchInvoke(id: id, command: command, payload: payload)
        case .subscribe(let id, let command, let payload):
            await dispatchSubscribe(id: id, command: command, payload: payload)
        case .unsubscribe(let id):
            subscriptions[id]?.cancel()
            subscriptions.removeValue(forKey: id)
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
        case .ok(let data):
            // Single-shot result on a "subscribe" call: emit one event then end.
            try? await webView.deliver(.event(id: id, chunk: data))
            try? await webView.deliver(.end(id: id))
        case .failure(let err):
            try? await webView.deliver(.replyError(id: id, error: err))
        case .stream(let stream):
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await chunk in stream {
                        if Task.isCancelled { break }
                        try await self.webView.deliver(.event(id: id, chunk: chunk))
                    }
                    try? await self.webView.deliver(.end(id: id))
                } catch let err as BridgeError {
                    try? await self.webView.deliver(.replyError(id: id, error: err))
                } catch {
                    try? await self.webView.deliver(.replyError(
                        id: id,
                        error: BridgeError(code: BridgeError.handler, message: "\(error)")
                    ))
                }
                self.subscriptions.removeValue(forKey: id)
            }
            subscriptions[id] = task
        }
    }

    private func deliver(_ result: InvocationResult, id: UInt64) async {
        switch result {
        case .ok(let data):
            try? await webView.deliver(.reply(id: id, ok: data))
        case .failure(let err):
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
}
