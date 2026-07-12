import Foundation

/// Plugin exposing the `net.*` command set: a native, CORS-free HTTP client the
/// web app can drive from JS. The cross-platform counterpart to `fetch` — but
/// running on the native side, so it isn't bound by the WebView's same-origin /
/// CORS policy and can set headers a page can't (Authorization, custom
/// user-agents), reach LAN appliances, and talk to third-party APIs that don't
/// send CORS headers.
///
/// **Opt-in.** Register it explicitly with a platform client:
/// `ctx.use(NetPlugin(URLSessionNetworkClient()))` on desktop/Apple,
/// `ctx.use(NetPlugin(AndroidNetworkClient()))` on Android. Not auto-installed —
/// arbitrary outbound requests from the native side are powerful, so an app
/// opts in the same way it does for `process.*`.
///
/// **Same transport as remote AI.** The injected `NetworkClient` is exactly
/// what the remote-image `AIBackend` providers consume, so there's one HTTP
/// abstraction and (on Android) one RPC bridge behind both surfaces.
///
/// ## Commands
/// - `net.request(NetRequestArgs)` → ``NetResponseResult``. A unary request;
///   the response is returned whatever its status (a 4xx/5xx is a `status`, not
///   an error) — only a transport failure throws `E_NET`.
/// - `net.download(NetDownloadArgs)` → stream of ``NetDownloadChunk``. Streams a
///   file to `destPath` with `progress` events then a terminal `done` carrying
///   the written path; verifies `sha256` when supplied.
public struct NetPlugin: Plugin {
    public static let pluginName = "net"

    private let client: any NetworkClient

    public init(_ client: any NetworkClient) {
        self.client = client
    }

    public func register(into registry: CommandRegistry, app _: any AppContext) {
        let client = client

        registry.register("net.request", typed: { (args: NetRequestArgs, _) async throws -> NetResponseResult in
            // Require an absolute URL with a scheme. `URL(string:)` is lenient on
            // swift-corelibs (an empty / scheme-less string yields a non-nil URL
            // there, unlike Darwin), so check the scheme explicitly for
            // cross-platform-consistent rejection.
            guard let url = URL(string: args.url), url.scheme?.isEmpty == false else {
                throw BridgeError(code: BridgeError.net, message: "invalid url: \(args.url)")
            }
            var body: Data?
            if let base64 = args.bodyBase64 {
                guard let decoded = Data(base64Encoded: base64) else {
                    throw BridgeError(code: BridgeError.net, message: "bodyBase64 is not valid base64")
                }
                body = decoded
            }
            let request = NetRequest(
                method: args.method ?? "GET",
                url: url,
                headers: args.headers ?? [:],
                body: body,
                timeout: args.timeoutMs.map { Double($0) / 1000.0 } ?? 60
            )
            let response = try await client.send(request)
            return NetResponseResult(
                status: response.status,
                headers: response.headers,
                bodyBase64: response.body.base64EncodedString()
            )
        })

        registry.registerStream(
            "net.download",
            typed: { (args: NetDownloadArgs, _) -> AsyncThrowingStream<NetDownloadChunk, any Error> in
                guard let url = URL(string: args.url), url.scheme?.isEmpty == false else {
                    return AsyncThrowingStream {
                        $0.finish(throwing: BridgeError(code: BridgeError.net, message: "invalid url: \(args.url)"))
                    }
                }
                let request = NetDownloadRequest(
                    url: url,
                    destination: URL(fileURLWithPath: args.destPath),
                    headers: args.headers ?? [:],
                    sha256: args.sha256
                )
                return AsyncThrowingStream { continuation in
                    let task = Task {
                        do {
                            for try await event in client.download(request) {
                                continuation.yield(NetDownloadChunk(event))
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        )
    }
}

// MARK: - Wire types (JS-facing)

/// `net.request` arguments. Body rides as base64 (`bodyBase64`) so binary
/// payloads survive the JSON bridge; `timeoutMs` is milliseconds.
public struct NetRequestArgs: Sendable, Codable, Equatable {
    public var method: String?
    public var url: String
    public var headers: [String: String]?
    public var bodyBase64: String?
    public var timeoutMs: Int?

    public init(
        method: String? = nil,
        url: String,
        headers: [String: String]? = nil,
        bodyBase64: String? = nil,
        timeoutMs: Int? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.bodyBase64 = bodyBase64
        self.timeoutMs = timeoutMs
    }
}

/// `net.request` result. `bodyBase64` is always present (empty string for an
/// empty body); the page decodes it or interprets `status` / `headers` first.
public struct NetResponseResult: Sendable, Codable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var bodyBase64: String

    public init(status: Int, headers: [String: String], bodyBase64: String) {
        self.status = status
        self.headers = headers
        self.bodyBase64 = bodyBase64
    }
}

/// `net.download` arguments. `destPath` is where the file is written on the
/// native side (a filesystem path); `sha256` (lowercase hex) is verified on
/// completion when present.
public struct NetDownloadArgs: Sendable, Codable, Equatable {
    public var url: String
    public var destPath: String
    public var headers: [String: String]?
    public var sha256: String?

    public init(url: String, destPath: String, headers: [String: String]? = nil, sha256: String? = nil) {
        self.url = url
        self.destPath = destPath
        self.headers = headers
        self.sha256 = sha256
    }
}

/// One `net.download` stream frame — the JS-facing encoding of
/// ``NetDownloadEvent`` (a run of `progress`, then a terminal `done` with the
/// written `path`).
public struct NetDownloadChunk: Sendable, Codable, Equatable {
    public var type: String
    public var bytesDownloaded: Int64?
    public var totalBytes: Int64?
    public var path: String?

    public init(_ event: NetDownloadEvent) {
        type = event.type
        bytesDownloaded = event.bytesDownloaded
        totalBytes = event.totalBytes
        path = event.path
    }
}
