#if os(Android)
    import CSwiftPWAAndroidJNI
    import Foundation
    import SwiftPWACore

    /// Thin Swift wrapper over the C shim's generic Swift→Kotlin RPC
    /// (`swiftpwa_android_rpc`) used by the System* plugins
    /// (clipboard, notifications, dialog, biometrics, updater install).
    ///
    /// The shim hops to the JVM main thread before driving the
    /// underlying Android API where required (most of these need it),
    /// so callers can invoke from any concurrency domain. The result
    /// is parsed as JSON; a `null` result decodes as `nil`.
    ///
    /// Errors come back as `BridgeError(code: .handler, message:)`.
    /// Method names are bare identifiers like `"clipboard.read"` —
    /// the Kotlin `SwiftPWABridge.handleRpc` `when` block dispatches.
    enum AndroidRPC {
        /// Invoke `method` with `args` (encoded to JSON) and decode the
        /// JSON result as `R`. `R == NoResult` for void-returning methods.
        static func call<R: Decodable>(
            _ method: String,
            _ args: some Encodable,
            as _: R.Type = R.self
        ) async throws -> R {
            let argsJSON = try Self.encodeArgs(args)
            let resultJSON = try await rawCall(method, argsJSON: argsJSON)
            guard let resultJSON, !resultJSON.isEmpty, resultJSON != "null" else {
                if R.self == NoResult.self {
                    return NoResult() as! R
                }
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "android rpc \(method) returned null but expected \(R.self)"
                )
            }
            guard let data = resultJSON.data(using: .utf8) else {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "android rpc \(method) returned non-UTF8 result"
                )
            }
            do {
                return try JSONDecoder().decode(R.self, from: data)
            } catch {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "android rpc \(method) result decode failed: \(error)"
                )
            }
        }

        /// Invoke `method` with no args and ignore the result. Convenience
        /// over the Encodable/Decodable form for void→void calls.
        static func callVoid(_ method: String) async throws {
            _ = try await rawCall(method, argsJSON: "{}")
        }

        // MARK: - Internals

        private static func encodeArgs(_ args: some Encodable) throws -> String {
            // Special-case `EmptyArgs` → "{}" so methods that take no args
            // don't have to spell it out at the call site.
            if args is EmptyArgs {
                return "{}"
            }
            let data = try JSONEncoder().encode(args)
            return String(data: data, encoding: .utf8) ?? "{}"
        }

        private static func rawCall(_ method: String, argsJSON: String) async throws -> String? {
            try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<String?, any Error>) in
                let box = RPCBox(continuation: cont)
                let user = Unmanaged.passRetained(box).toOpaque()
                method.withCString { mPtr in
                    argsJSON.withCString { aPtr in
                        swiftpwa_android_rpc(mPtr, aPtr, rpcDoneTrampoline, user)
                    }
                }
            }
        }
    }

    /// Empty-args sentinel for RPC methods that take no input.
    struct EmptyArgs: Encodable {}

    /// Empty-result sentinel for RPC methods that return nothing.
    struct NoResult: Decodable {}

    /// Heap-boxed continuation ferried through `swiftpwa_android_rpc`.
    final class RPCBox: @unchecked Sendable {
        let continuation: CheckedContinuation<String?, any Error>
        init(continuation: CheckedContinuation<String?, any Error>) {
            self.continuation = continuation
        }
    }

    /// `@convention(c)` callback fired by the shim once the Kotlin side
    /// invokes `nativeRpcDone`. Always one-shot: the box is consumed.
    let rpcDoneTrampoline: @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?
    ) -> Void = { resultPtr, errorPtr, userData in
        guard let userData else { return }
        let box = Unmanaged<RPCBox>.fromOpaque(userData).takeRetainedValue()
        if let errorPtr {
            box.continuation.resume(throwing: BridgeError(
                code: BridgeError.handler,
                message: String(cString: errorPtr)
            ))
            return
        }
        if let resultPtr {
            box.continuation.resume(returning: String(cString: resultPtr))
        } else {
            box.continuation.resume(returning: nil)
        }
    }
#endif
