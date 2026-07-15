import Foundation

/// Thread-safe registry of named JS-callable command handlers.
///
/// Handlers are stored in a lock-guarded dictionary. Registration is
/// synchronous so the user's `configure` closure can run on a thread
/// that may not be pumping Swift's main-actor executor (e.g. before
/// `gtk_main()` starts on Linux). Handlers themselves are still async
/// closures, so `dispatch` stays async.
///
/// The registry is the single fan-in point for the JS↔Swift bridge:
/// each backend's webview adapter funnels every inbound `invoke` /
/// `subscribe` frame through `dispatch(_:)`.
public final class CommandRegistry: @unchecked Sendable {
    public typealias Handler = @Sendable (CommandContext) async -> InvocationResult

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    /// Per-command inbound-buffer bound for `registerSession` commands, read by
    /// `BridgeRuntime` at subscribe time to size the session's inbound stream.
    private var sessionBounds: [String: Int] = [:]

    public init() {}

    /// The client→server inbound buffer bound registered for a duplex-session
    /// command, or `nil` if `name` isn't a `registerSession` command.
    public func sessionBufferBound(for name: String) -> Int? {
        lock.withLock { sessionBounds[name] }
    }

    // MARK: - Registration

    /// Register a raw handler. Caller is responsible for decoding/encoding payloads.
    public func register(_ name: String, _ handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[name] = handler
    }

    /// Register a typed unary handler. JSON decode/encode is handled for you.
    /// Errors thrown by `body` become `BridgeError(code: .handler, ...)`.
    public func register<Args: Decodable & Sendable>(
        _ name: String,
        typed body: @escaping @Sendable (Args, CommandContext) async throws -> some Encodable & Sendable
    ) {
        register(name) { context in
            let args: Args
            do {
                args = try context.invocation.decode(Args.self)
            } catch {
                return .failure(BridgeError(
                    code: BridgeError.decode,
                    message: "failed to decode args for \(name): \(error)"
                ))
            }
            do {
                let result = try await body(args, context)
                let data = try JSONEncoder().encode(result)
                return .ok(data)
            } catch let bridge as BridgeError {
                return .failure(bridge)
            } catch {
                return .failure(BridgeError(
                    code: BridgeError.handler,
                    message: "\(error)"
                ))
            }
        }
    }

    /// Register a typed streaming handler. Each non-throwing yield from
    /// `body` is forwarded as a JSON-encoded `event` frame; the stream's
    /// completion produces an `end` frame.
    public func registerStream<Args: Decodable & Sendable, Chunk: Encodable & Sendable>(
        _ name: String,
        typed body: @escaping @Sendable (Args, CommandContext) -> AsyncThrowingStream<Chunk, any Error>
    ) {
        register(name) { context in
            let args: Args
            do {
                args = try context.invocation.decode(Args.self)
            } catch {
                return .failure(BridgeError(
                    code: BridgeError.decode,
                    message: "failed to decode args for \(name): \(error)"
                ))
            }
            let upstream = body(args, context)
            let translated = AsyncThrowingStream<Data, any Error> { continuation in
                let task = Task {
                    do {
                        for try await chunk in upstream {
                            let data = try JSONEncoder().encode(chunk)
                            continuation.yield(data)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return .stream(translated)
        }
    }

    /// Register a typed **duplex session** handler. Opened by JS via
    /// `__SWIFT_PWA__.session(name, openArgs, handlers)` (a `subscribe` under
    /// the hood): `openArgs` decodes into `Args`, client `push` frames arrive
    /// as a typed `BridgeInbound<Frame>`, and each yield from the returned
    /// stream becomes a downstream `event` frame (completion → `end`).
    ///
    /// The inbound stream is live for the session's lifetime and finishes when
    /// the client closes (`unsubscribe`), the returned stream completes, or the
    /// window tears down — so a `for await frame in inbound` loop terminates
    /// cleanly on any of those.
    ///
    /// `maxBufferedFrames` bounds the client→server buffer (drop-oldest, since
    /// the JS `postMessage` can't be back-pressured); overflow drops are counted
    /// in `BridgeInbound.droppedCount`. Default 256.
    public func registerSession<
        Args: Decodable & Sendable,
        Frame: Decodable & Sendable,
        Chunk: Encodable & Sendable
    >(
        _ name: String,
        maxBufferedFrames: Int = 256,
        typed body: @escaping @Sendable (Args, BridgeInbound<Frame>, CommandContext)
            -> AsyncThrowingStream<Chunk, any Error>
    ) {
        // Record the per-command buffer bound so `BridgeRuntime` can size the
        // inbound stream at subscribe time (before this handler closure runs).
        lock.withLock { sessionBounds[name] = max(1, maxBufferedFrames) }
        register(name) { context in
            let args: Args
            do {
                args = try context.invocation.decode(Args.self)
            } catch {
                return .failure(BridgeError(
                    code: BridgeError.decode,
                    message: "failed to decode open args for \(name): \(error)"
                ))
            }
            // A session opened via `subscribe` always carries an inbound side
            // (BridgeRuntime creates it before dispatch). If the command is
            // reached some other way (e.g. `invoke`), fall back to an empty,
            // already-finished inbound so the handler's loop just exits.
            let session = context.sessionInbound
            let rawInbound = session?.frames ?? AsyncStream { $0.finish() }
            let inbound = BridgeInbound<Frame>(
                rawInbound, command: name, droppedCount: { session?.droppedCount ?? 0 }
            )
            let upstream = body(args, inbound, context)
            let translated = AsyncThrowingStream<Data, any Error> { continuation in
                let task = Task {
                    do {
                        for try await chunk in upstream {
                            let data = try JSONEncoder().encode(chunk)
                            continuation.yield(data)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return .stream(translated)
        }
    }

    public func unregister(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: name)
        sessionBounds.removeValue(forKey: name)
    }

    public func has(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return handlers[name] != nil
    }

    public func names() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(handlers.keys)
    }

    // MARK: - Dispatch

    /// Look up and invoke the handler for `context.invocation.command`.
    /// Returns `.failure(.notFound)` if no handler is registered.
    public func dispatch(_ context: CommandContext) async -> InvocationResult {
        let handler: Handler? = {
            lock.lock()
            defer { lock.unlock() }
            return handlers[context.invocation.command]
        }()
        guard let handler else {
            return .failure(BridgeError(
                code: BridgeError.notFound,
                message: "no command registered for \"\(context.invocation.command)\""
            ))
        }
        return await handler(context)
    }
}
