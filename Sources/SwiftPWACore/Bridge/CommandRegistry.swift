import Foundation

/// Thread-safe registry of named JS-callable command handlers.
///
/// Handlers are async, sendable closures keyed by command name.
/// Use `register(_:_:)` for the raw `Data`-in / `Data`-out form, or
/// `register(_:typed:)` to get automatic JSON encode/decode.
///
/// The registry is the single fan-in point for the JS↔Swift bridge:
/// each backend's webview adapter funnels every inbound `invoke` /
/// `subscribe` frame through `dispatch(_:context:)`.
public actor CommandRegistry {
    public typealias Handler = @Sendable (CommandContext) async -> InvocationResult

    private var handlers: [String: Handler] = [:]

    public init() {}

    // MARK: - Registration

    /// Register a raw handler. Caller is responsible for decoding/encoding payloads.
    public func register(_ name: String, _ handler: @escaping Handler) {
        handlers[name] = handler
    }

    /// Register a typed unary handler. JSON decode/encode is handled for you.
    /// Errors thrown by `body` become `BridgeError(code: .handler, ...)`.
    public func register<Args, Out>(
        _ name: String,
        typed body: @escaping @Sendable (Args, CommandContext) async throws -> Out
    ) where Args: Decodable & Sendable, Out: Encodable & Sendable {
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
    public func registerStream<Args, Chunk>(
        _ name: String,
        typed body: @escaping @Sendable (Args, CommandContext) -> AsyncThrowingStream<Chunk, any Error>
    ) where Args: Decodable & Sendable, Chunk: Encodable & Sendable {
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

    public func unregister(_ name: String) {
        handlers.removeValue(forKey: name)
    }

    public func has(_ name: String) -> Bool {
        handlers[name] != nil
    }

    public func names() -> [String] {
        Array(handlers.keys)
    }

    // MARK: - Dispatch

    /// Look up and invoke the handler for `context.invocation.command`.
    /// Returns `.failure(.notFound)` if no handler is registered.
    public func dispatch(_ context: CommandContext) async -> InvocationResult {
        guard let handler = handlers[context.invocation.command] else {
            return .failure(BridgeError(
                code: BridgeError.notFound,
                message: "no command registered for \"\(context.invocation.command)\""
            ))
        }
        return await handler(context)
    }
}
