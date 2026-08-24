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
    private var subscriptions: [UInt64: Entry] = [:]
    /// In-flight `invoke` handlers, so `stop()` can cancel work that would
    /// otherwise keep running — and delivering — against a torn-down web view.
    private var invocations: [UInt64: Entry] = [:]
    /// Inbound sinks for open duplex sessions (see `registerSession`). One is
    /// created per `subscribe` (before dispatch, so a `push` that the serial
    /// pump handles next always finds it); plain-stream handlers simply never
    /// read theirs. `push` frames route here; teardown finishes it. Each sink
    /// pairs the bounded continuation with a drop counter incremented when the
    /// buffer overflows (drop-oldest), surfaced to the handler as
    /// `BridgeInbound.droppedCount`.
    private var sessionInbound: [UInt64: SessionSink] = [:]
    /// The document currently occupying this window, as announced by
    /// `bridge.js`'s `hello` frame. A window outlives the documents loaded into
    /// it, so this is what separates "the page asked" from "a page that is
    /// gone asked".
    private var currentEpoch: String?
    /// Bumped every time the window's document is replaced.
    ///
    /// Correlation ids restart at 1 in each document, so ids *are* reused
    /// across a navigation — and cancellation is cooperative, so a task torn
    /// down by the navigation runs its own cleanup afterwards, by id. Without
    /// this the departing task's cleanup deletes the entry the new document
    /// has since put in that slot, silently killing a live subscription.
    /// Measured: with three documents loaded in turn, an emit reached the live
    /// one zero times.
    private var generation: UInt64 = 0

    /// Default bound on buffered client frames per session when a
    /// `registerSession` command doesn't specify one — drops oldest on overflow
    /// so a flooding client can't grow memory unboundedly.
    static let defaultSessionInboundBuffer = 256

    private struct SessionSink {
        let continuation: AsyncStream<Data>.Continuation
        let drops: DropCounter
        let generation: UInt64
    }

    /// A running task, tagged with the document generation that started it.
    private struct Entry {
        let task: Task<Void, Never>
        let generation: UInt64
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
        let oldPump = lock.withLock {
            let p = pumpTask
            pumpTask = nil
            currentEpoch = nil
            return p
        }
        oldPump?.cancel()
        cancelDocumentWork()
    }

    /// Cancel everything the current document opened, leaving the pump running.
    ///
    /// Used both by ``stop()`` (window teardown) and by a navigation, where the
    /// window and its inbound channel survive but every correlation the old
    /// document held is now meaningless.
    private func cancelDocumentWork() {
        let (oldSubs, oldInbound, oldInvokes) = lock.withLock {
            let s = subscriptions
            let i = sessionInbound
            let v = invocations
            subscriptions.removeAll()
            sessionInbound.removeAll()
            invocations.removeAll()
            generation &+= 1
            return (s, i, v)
        }
        for (_, entry) in oldSubs { entry.task.cancel() }
        for (_, entry) in oldInvokes { entry.task.cancel() }
        for (_, sink) in oldInbound { sink.continuation.finish() }
    }

    /// Test hook: returns whether a streaming subscription is currently
    /// active for the given correlation id.
    public func hasActiveSubscription(id: UInt64) -> Bool {
        lock.withLock { subscriptions[id] != nil }
    }

    deinit {
        let (oldPump, oldSubs, oldInbound, oldInvokes) = lock.withLock {
            (pumpTask, subscriptions, sessionInbound, invocations)
        }
        oldPump?.cancel()
        for (_, entry) in oldSubs { entry.task.cancel() }
        for (_, entry) in oldInvokes { entry.task.cancel() }
        for (_, sink) in oldInbound { sink.continuation.finish() }
    }

    // MARK: - private

    private func handle(_ frame: InboundFrame) async {
        if case let .hello(epoch) = frame {
            adoptDocument(epoch)
            return
        }
        // A frame from a document that has already been navigated away from —
        // typically an `unsubscribe` its teardown posted on the way out. Its
        // correlation id belongs to a table that no longer exists, and acting
        // on it would reach into the live document's.
        guard accepts(frame.epoch) else { return }
        let epoch = frame.epoch
        let generation = lock.withLock { self.generation }

        switch frame {
        case .hello:
            break // handled above, ahead of the epoch check
        case let .invoke(id, command, payload, _):
            // Concurrent, unlike everything below it. An `invoke` is
            // independent and correlated by id, so awaiting it here only
            // achieved one thing: one slow handler stalled every later frame on
            // the window. Measured — `geo.current` pending on a first-run
            // permission prompt, after which no other command could complete,
            // including ones the page needed to *show* the prompt's outcome.
            //
            // The other three cases stay ordered on purpose: `subscribe`
            // registers its inbound sink synchronously so a following `push`
            // finds it, and `unsubscribe` has to find what `subscribe`
            // registered. Making those concurrent would trade this bug for a
            // race.
            let task = Task { [weak self] in
                await self?.dispatchInvoke(id: id, command: command, payload: payload, epoch: epoch)
                self?.finishInvocation(id, generation: generation)
            }
            lock.withLock { invocations[id] = Entry(task: task, generation: generation) }
        case let .subscribe(id, command, payload, _):
            await dispatchSubscribe(
                id: id,
                command: command,
                payload: payload,
                epoch: epoch,
                generation: generation
            )
        case let .unsubscribe(id, _):
            removeSubscription(id, generation: generation)
        case let .push(id, payload, _):
            routePush(id: id, payload: payload)
        }
    }

    /// A new document has taken over this window.
    ///
    /// `bridge.js` posts `hello` at document start, before the page's own
    /// scripts run, so everything the previous document subscribed is torn down
    /// before this one opens anything. That ordering is the whole point: it
    /// makes a navigation behave like a window close and reopen, which is what
    /// the per-window `BridgeRuntime` lifetime otherwise hides.
    private func adoptDocument(_ epoch: String) {
        let isNewDocument = lock.withLock {
            guard currentEpoch != epoch else { return false }
            currentEpoch = epoch
            return true
        }
        guard isNewDocument else { return }
        cancelDocumentWork()
    }

    /// Whether a frame stamped with `epoch` belongs to the live document.
    ///
    /// A `nil` epoch is accepted: it means the frame was built in Swift rather
    /// than by `bridge.js` (tests, a custom backend), and there is no document
    /// to attribute it to. An epoch seen before any `hello` is adopted as the
    /// current one so its replies are still stamped correctly.
    private func accepts(_ epoch: String?) -> Bool {
        guard let epoch else { return true }
        return lock.withLock {
            if currentEpoch == nil {
                currentEpoch = epoch
                return true
            }
            return currentEpoch == epoch
        }
    }

    private func finishInvocation(_ id: UInt64, generation: UInt64) {
        lock.withLock {
            guard invocations[id]?.generation == generation else { return }
            invocations.removeValue(forKey: id)
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

    private func dispatchInvoke(id: UInt64, command: String, payload: Data, epoch: String?) async {
        guard let app = app as? any AppContext else { return }
        let inv = Invocation(id: id, command: command, payload: payload)
        let context = CommandContext(invocation: inv, originWindow: windowID, appContext: app)
        let result = await registry.dispatch(context)
        await deliver(result, id: id, epoch: epoch)
    }

    private func dispatchSubscribe(
        id: UInt64,
        command: String,
        payload: Data,
        epoch: String?,
        generation: UInt64
    ) async {
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
        lock.withLock {
            sessionInbound[id] = SessionSink(
                continuation: inboundContinuation,
                drops: drops,
                generation: generation
            )
        }

        let context = CommandContext(
            invocation: inv,
            originWindow: windowID,
            appContext: app,
            sessionInbound: SessionInbound(frames: inbound, droppedCount: { drops.value })
        )
        let result = await registry.dispatch(context)
        switch result {
        case let .ok(data):
            try? await webView.deliver(.event(id: id, chunk: data, epoch: epoch))
            try? await webView.deliver(.end(id: id, epoch: epoch))
            finishInbound(id, generation: generation)
        case let .failure(err):
            try? await webView.deliver(.replyError(id: id, error: err, epoch: epoch))
            finishInbound(id, generation: generation)
        case let .stream(stream):
            // Every frame carries the epoch of the document that *opened* the
            // stream, not the one live when it emits. Cancellation is
            // cooperative, so a stream torn down by a navigation can still be
            // mid-`deliver`; stamping it with its own document is what stops
            // that last chunk resolving against the new one's table.
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await chunk in stream {
                        if Task.isCancelled { break }
                        try await webView.deliver(.event(id: id, chunk: chunk, epoch: epoch))
                    }
                    try? await webView.deliver(.end(id: id, epoch: epoch))
                } catch let err as BridgeError {
                    try? await self.webView.deliver(.replyError(id: id, error: err, epoch: epoch))
                } catch {
                    try? await webView.deliver(.replyError(
                        id: id,
                        error: BridgeError(code: BridgeError.handler, message: "\(error)"),
                        epoch: epoch
                    ))
                }
                removeSubscription(id, generation: generation)
            }
            setSubscription(id, task, generation: generation)
        }
    }

    private func deliver(_ result: InvocationResult, id: UInt64, epoch: String?) async {
        switch result {
        case let .ok(data):
            try? await webView.deliver(.reply(id: id, ok: data, epoch: epoch))
        case let .failure(err):
            try? await webView.deliver(.replyError(id: id, error: err, epoch: epoch))
        case .stream:
            // `invoke` is unary by contract; treat a stream result as an error.
            try? await webView.deliver(.replyError(
                id: id,
                error: BridgeError(
                    code: BridgeError.handler,
                    message: "command returned a stream but was called via invoke()"
                ),
                epoch: epoch
            ))
        }
    }

    private func setSubscription(_ id: UInt64, _ task: Task<Void, Never>, generation: UInt64) {
        lock.withLock { subscriptions[id] = Entry(task: task, generation: generation) }
    }

    /// Drop the subscription registered for `id` **by this generation**. An
    /// unsubscribe from the live document passes the current generation; a
    /// task cancelled by a navigation passes the one it was started under, and
    /// so leaves the new document's entry for the same id alone.
    private func removeSubscription(_ id: UInt64, generation: UInt64) {
        let (entry, sink) = lock.withLock {
            let e = subscriptions[id]?.generation == generation
                ? subscriptions.removeValue(forKey: id) : nil
            let s = sessionInbound[id]?.generation == generation
                ? sessionInbound.removeValue(forKey: id) : nil
            return (e, s)
        }
        entry?.task.cancel()
        sink?.continuation.finish()
    }

    /// Finish + drop a session's inbound stream without cancelling a
    /// subscription task (used on the unary `.ok` / `.failure` subscribe paths,
    /// which have no task to cancel).
    private func finishInbound(_ id: UInt64, generation: UInt64) {
        let sink = lock.withLock {
            guard sessionInbound[id]?.generation == generation else { return SessionSink?.none }
            return sessionInbound.removeValue(forKey: id)
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
