import Foundation

/// Built-in plugin exposing the `events.*` command set: the JS side of the
/// runtime-owned ``EventBus`` server-push primitive.
///
/// Registered eagerly by every backend's `AppContext.init` (alongside
/// `WindowPlugin` / `AppPlugin` / `PlatformInfoPlugin`) — never opt-in — so the
/// JS `on(channel, cb)` / `emit(channel, payload)` sugar in `bridge.js` works
/// out of the box on every platform.
///
/// - `events.subscribe` (streaming): open a stream of payloads for a channel.
///   Each `emit` on that channel — whether from Swift (``AppContext/emit(_:_:retain:)``)
///   or from another window's `events.emit` — arrives as one `event` frame. A
///   retained channel replays its latest value immediately on subscribe.
/// - `events.emit` (unary): publish a payload on a channel from JS. Fans out to
///   every subscriber in every window, so it doubles as a cross-window message
///   bus.
public struct EventsPlugin: Plugin {
    public static let pluginName = "events"
    public init() {}

    public func register(into registry: CommandRegistry, app: any AppContext) {
        let bus = app.events

        // Streaming subscribe. Registered as a *raw* handler because the
        // payload bytes the bus vends are already complete JSON — routing them
        // through the typed `registerStream` (which JSON-encodes each chunk)
        // would double-encode them into a base64 string.
        registry.register("events.subscribe") { context in
            let args: EventSubscribeArgs
            do {
                args = try context.invocation.decode(EventSubscribeArgs.self)
            } catch {
                return .failure(BridgeError(
                    code: BridgeError.decode,
                    message: "events.subscribe requires a string \"channel\": \(error)"
                ))
            }
            let stream = AsyncThrowingStream<Data, any Error> { continuation in
                let subscription = bus.subscribe(args.channel) { payload in
                    continuation.yield(payload)
                }
                // BridgeRuntime cancels the consuming task on unsubscribe or
                // window teardown, which fires this termination handler — so the
                // bus subscription is released automatically. Same lifetime
                // contract as `window.subscribe`.
                continuation.onTermination = { _ in subscription.cancel() }
            }
            return .stream(stream)
        }

        // Unary emit from JS. The payload is arbitrary user JSON, so it is
        // extracted as raw bytes rather than decoded into a fixed type.
        registry.register("events.emit") { context in
            guard
                let object = try? JSONSerialization.jsonObject(
                    with: context.invocation.payload,
                    options: [.fragmentsAllowed]
                ) as? [String: Any],
                let channel = object["channel"] as? String
            else {
                return .failure(BridgeError(
                    code: BridgeError.decode,
                    message: "events.emit requires a string \"channel\""
                ))
            }
            let retain = (object["retain"] as? Bool) ?? false
            let payloadValue = object["payload"] ?? NSNull()
            let payloadData = (try? JSONSerialization.data(
                withJSONObject: payloadValue,
                options: [.fragmentsAllowed]
            )) ?? Data("null".utf8)
            bus.emit(channel, payload: payloadData, retain: retain)
            let ok = (try? JSONEncoder().encode(EmptyResult())) ?? Data("{}".utf8)
            return .ok(ok)
        }
    }
}

// MARK: - Argument types

public struct EventSubscribeArgs: Sendable, Codable {
    /// The channel to receive payloads from.
    public var channel: String
    public init(channel: String) { self.channel = channel }
}
