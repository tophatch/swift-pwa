#if os(Android)
    import Foundation
    import SwiftPWACore

    /// The `NetworkClient` for Android. Routes every request through the Kotlin
    /// RPC bridge rather than Swift's `URLSession`, because swift-corelibs
    /// `URLSession` (libcurl + BoringSSL) has no injectable CA trust store on
    /// Android — HTTPS fails with "unable to get local issuer certificate". The
    /// Kotlin side uses Android's own `HttpURLConnection` (system TLS + CA
    /// store), and — for a plain-`http://` LAN endpoint — is subject to the app's
    /// Network Security Config (see the bundler's `android.network.cleartext_domains`).
    ///
    /// `send` uses the `net.request` RPC; `download` reuses `AndroidFileDownload`
    /// (the byte-level-progress `net.downloadFile` path the model backends share).
    /// Wire it the same way as any platform backend:
    /// `ctx.use(NetPlugin(AndroidNetworkClient()))`.
    public struct AndroidNetworkClient: NetworkClient {
        public init() {}

        public func send(_ request: NetRequest) async throws -> NetResponse {
            let args = RequestArgs(
                method: request.method,
                url: request.url.absoluteString,
                headers: request.headers.isEmpty ? nil : request.headers,
                bodyBase64: request.body?.base64EncodedString(),
                timeoutMs: Int(request.timeout * 1000)
            )
            let result = try await AndroidRPC.call("net.request", args, as: ResponseResult.self)
            let body = result.bodyBase64.flatMap { Data(base64Encoded: $0) } ?? Data()
            return NetResponse(status: result.status, headers: result.headers ?? [:], body: body)
        }

        public func download(_ request: NetDownloadRequest) -> AsyncThrowingStream<NetDownloadEvent, any Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        try await AndroidFileDownload.download(
                            url: request.url.absoluteString,
                            destPath: request.destination.path,
                            sha256: request.sha256,
                            headers: request.headers,
                            onProgress: { bytesDone, totalBytes in
                                continuation.yield(.progress(bytesDownloaded: bytesDone, totalBytes: totalBytes))
                            }
                        )
                        continuation.yield(.done(path: request.destination.path))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        /// Open a receive-only WebSocket over the Kotlin `net.ws.*` RPC — Android's
        /// `HttpURLConnection` (which backs `send`/`download`) has no WebSocket, so
        /// the Kotlin side uses OkHttp and pushes each inbound frame to us as a
        /// host-event on a per-connection channel (the same side-channel pattern
        /// `net.downloadFile` uses for byte progress). This lets the remote-AI
        /// workflow provider report per-step ComfyUI `/ws` progress on Android too,
        /// instead of degrading to the throwing default and coarse polling.
        public func openWebSocket(
            _ request: NetWebSocketRequest
        ) -> AsyncThrowingStream<NetWebSocketEvent, any Error> {
            AsyncThrowingStream { continuation in
                let channel = Self.nextChannel()
                AndroidHostEventRouter.subscribe(channel: channel) { data in
                    guard let frame = try? JSONDecoder().decode(WebSocketFrame.self, from: data) else { return }
                    switch frame.type {
                    case "text":
                        if let text = frame.text { continuation.yield(.text(text)) }
                    case "binary":
                        if let b64 = frame.dataBase64, let bytes = Data(base64Encoded: b64) {
                            continuation.yield(.binary(bytes))
                        }
                    case "close":
                        continuation.finish()
                    case "error":
                        continuation.finish(throwing: BridgeError(
                            code: BridgeError.net,
                            message: "websocket closed: \(frame.message ?? "unknown error")"
                        ))
                    default:
                        break
                    }
                }

                let openTask = Task {
                    do {
                        _ = try await AndroidRPC.call("net.ws.open", OpenWebSocketArgs(
                            url: request.url.absoluteString,
                            channel: channel,
                            headers: request.headers.isEmpty ? nil : request.headers
                        ), as: NoResult.self)
                    } catch {
                        AndroidHostEventRouter.unsubscribe(channel: channel)
                        continuation.finish(throwing: error)
                    }
                }

                continuation.onTermination = { _ in
                    openTask.cancel()
                    AndroidHostEventRouter.unsubscribe(channel: channel)
                    // Best-effort close of the Kotlin-side socket. Idempotent: a
                    // socket already gone (close/error frame) is a no-op there.
                    Task { try? await AndroidRPC.call(
                        "net.ws.close", CloseWebSocketArgs(channel: channel), as: NoResult.self
                    ) }
                }
            }
        }

        // MARK: - Wire types

        private struct RequestArgs: Encodable {
            let method: String
            let url: String
            let headers: [String: String]?
            let bodyBase64: String?
            let timeoutMs: Int
        }

        private struct ResponseResult: Decodable {
            let status: Int
            let headers: [String: String]?
            let bodyBase64: String?
        }

        private struct OpenWebSocketArgs: Encodable {
            let url: String
            /// Host-event channel the Kotlin side pushes inbound frames on.
            let channel: String
            let headers: [String: String]?
        }

        private struct CloseWebSocketArgs: Encodable {
            let channel: String
        }

        /// A frame pushed from Kotlin on the WebSocket channel. `type` is one of
        /// `text` / `binary` / `close` / `error`; the other fields are populated
        /// per type (`text`, `dataBase64`, or `message`).
        private struct WebSocketFrame: Decodable {
            let type: String
            let text: String?
            let dataBase64: String?
            let message: String?
        }

        // MARK: - Channel naming

        /// A process-unique channel per socket. `AndroidHostEventRouter` is
        /// single-slot per channel, so concurrent sockets must not collide.
        private static func nextChannel() -> String {
            "net.ws.\(counter.next())"
        }

        private static let counter = ChannelCounter()

        private final class ChannelCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value: UInt64 = 0
            func next() -> UInt64 {
                lock.withLock {
                    value &+= 1
                    return value
                }
            }
        }
    }
#endif
