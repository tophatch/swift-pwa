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
    }
#endif
