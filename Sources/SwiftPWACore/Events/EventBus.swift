import Foundation

/// A runtime-owned, app-wide publish/subscribe bus for **server-initiated**
/// events — the Swift→JS push primitive.
///
/// The streaming `subscribe` machinery already lets JS *pull* a stream from
/// Swift, but every app that wants Swift to notify JS of something the client
/// didn't explicitly request (a file appeared, an import finished, a background
/// job progressed) otherwise has to hand-roll a catch-all "bus" stream and fan
/// unrelated events into it. `EventBus` makes that a first-class concept:
///
/// - **Named channels.** Publishers `emit(_:_:)` on a string channel; each live
///   subscriber to that channel receives the payload.
/// - **Fan-out across windows.** One bus is owned by the `AppContext`
///   (``AppContext/events``), so a single `emit` reaches subscribers in *every*
///   window — the multi-window broadcast that a per-window subscription can't do.
/// - **Retained "latest value".** `emit(..., retain: true)` remembers the last
///   payload on a channel and replays it to any subscriber that connects later,
///   closing the "client subscribed too late and missed the event" gap.
///
/// Payloads cross the bridge as raw JSON bytes (the same representation the
/// wire uses for `event` chunks), so no re-encoding happens between `emit` and
/// the JS `onChunk`. On the Swift side, prefer the typed
/// ``AppContext/emit(_:_:retain:)`` convenience, or the `Encodable` overload
/// here.
///
/// **Threading.** Lock-guarded and `Sendable`; `emit` may be called from any
/// thread (a background import task, a file-watcher callback, the UI thread).
/// Continuations are copied under the lock and yielded *outside* it, so a slow
/// or reentrant consumer can't deadlock a publisher.
public final class EventBus: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: UInt64 = 1
    private var subscribers: [String: [UInt64: @Sendable (Data) -> Void]] = [:]
    private var retained: [String: Data] = [:]

    public init() {}

    // MARK: - Publish

    /// Emit a raw-JSON payload on `channel` to every current subscriber.
    ///
    /// - Parameters:
    ///   - channel: The channel name.
    ///   - payload: The payload as complete JSON bytes (e.g. `{"path":"…"}` or
    ///     `"done"` or `null`). This is forwarded verbatim as the JS `onChunk`
    ///     argument.
    ///   - retain: When `true`, remembers this payload as the channel's latest
    ///     value and replays it to future subscribers until overwritten or
    ///     cleared via ``clearRetained(_:)``.
    public func emit(_ channel: String, payload: Data, retain: Bool = false) {
        let sinks: [@Sendable (Data) -> Void] = lock.withLock {
            if retain { retained[channel] = payload }
            return Array((subscribers[channel] ?? [:]).values)
        }
        for sink in sinks { sink(payload) }
    }

    /// Emit an `Encodable` payload on `channel`. Encodes with `JSONEncoder`
    /// then forwards to ``emit(_:payload:retain:)``.
    public func emit(_ channel: String, _ payload: some Encodable, retain: Bool = false) throws {
        let data = try JSONEncoder().encode(payload)
        emit(channel, payload: data, retain: retain)
    }

    /// Emit a payload-less signal on `channel` (JS receives `null`).
    public func signal(_ channel: String, retain: Bool = false) {
        emit(channel, payload: Data("null".utf8), retain: retain)
    }

    /// Forget a channel's retained value so later subscribers no longer replay it.
    public func clearRetained(_ channel: String) {
        lock.withLock { _ = retained.removeValue(forKey: channel) }
    }

    // MARK: - Subscribe

    /// Register `sink` to receive every payload emitted on `channel`, and
    /// return a token whose ``EventSubscription/cancel()`` deregisters it.
    ///
    /// If the channel has a retained latest value, `sink` is invoked with it
    /// synchronously before this call returns (best-effort: a publish racing
    /// exactly with this call may be observed before the retained replay).
    ///
    /// This is the low-level primitive the built-in `EventsPlugin` wires to the
    /// bridge; app code usually subscribes from JS via `on(channel, cb)`.
    public func subscribe(_ channel: String, _ sink: @escaping @Sendable (Data) -> Void) -> EventSubscription {
        let (id, last) = lock.withLock { () -> (UInt64, Data?) in
            let id = nextID
            nextID &+= 1
            subscribers[channel, default: [:]][id] = sink
            return (id, retained[channel])
        }
        if let last { sink(last) }
        return EventSubscription { [weak self] in
            self?.removeSubscriber(channel: channel, id: id)
        }
    }

    private func removeSubscriber(channel: String, id: UInt64) {
        lock.withLock {
            subscribers[channel]?.removeValue(forKey: id)
            if subscribers[channel]?.isEmpty == true {
                subscribers.removeValue(forKey: channel)
            }
        }
    }

    /// Number of live subscribers on `channel` (test / diagnostics hook).
    public func subscriberCount(_ channel: String) -> Int {
        lock.withLock { subscribers[channel]?.count ?? 0 }
    }
}

/// Opaque handle returned by ``EventBus/subscribe(_:_:)``. Calling
/// ``cancel()`` deregisters the sink; it is idempotent and safe to call from
/// any thread.
public final class EventSubscription: Sendable {
    private let onCancel: @Sendable () -> Void

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        onCancel()
    }
}
