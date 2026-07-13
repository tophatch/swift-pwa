import Foundation

/// A cross-platform HTTP transport. The single seam that abstracts "make an
/// HTTP request" over the platform differences swift-pwa has to live with —
/// notably that swift-corelibs `URLSession` on Android has no injectable CA
/// trust store, so HTTPS there must route through the Kotlin RPC bridge (see
/// `AndroidNetworkClient`), while Apple / Linux / Windows use `URLSession`
/// directly (`URLSessionNetworkClient`).
///
/// Injected the same way `ProcessRunner` is into `ProcessPlugin`: an app hands
/// the platform-appropriate client to `NetPlugin` (and, later, to the remote
/// `AIBackend` providers), picking it per build —
/// `URLSessionNetworkClient()` on desktop/Apple, `AndroidNetworkClient()` on
/// Android. This is the one abstraction the JS `net.*` plugin and the remote AI
/// tier both consume, so there's one transport and one Android RPC, not two.
public protocol NetworkClient: Sendable {
    /// Perform a unary request and return the full response. Throws
    /// `BridgeError(code: .net)` on a transport failure (the response *itself*
    /// — including a non-2xx status — is returned, not thrown; the caller
    /// decides what a 4xx/5xx means).
    func send(_ request: NetRequest) async throws -> NetResponse

    /// Stream a download to `request.destination`, yielding periodic
    /// `progress` events then a terminal `done` carrying the written path.
    /// Verifies `request.sha256` when supplied. The path-first counterpart to
    /// `send`, for large payloads that shouldn't cross the bridge as base64
    /// (mirrors `fs`'s stance and reuses the existing model-download plumbing).
    func download(_ request: NetDownloadRequest) -> AsyncThrowingStream<NetDownloadEvent, any Error>

    /// Open a **receive-only** WebSocket and stream inbound frames until the
    /// socket closes (or the returned stream is torn down). Used for server-push
    /// progress such as ComfyUI's `/ws`. Default: throws `E_NET` "unsupported" —
    /// a client that has no WebSocket transport (e.g. `AndroidNetworkClient`
    /// until its RPC lands) inherits it, and a consumer degrades gracefully.
    func openWebSocket(_ request: NetWebSocketRequest) -> AsyncThrowingStream<NetWebSocketEvent, any Error>
}

public extension NetworkClient {
    func openWebSocket(_: NetWebSocketRequest) -> AsyncThrowingStream<NetWebSocketEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: BridgeError(
            code: BridgeError.net, message: "WebSocket is not supported by this NetworkClient"
        )) }
    }
}

// MARK: - Value types (Swift-facing)

/// A unary HTTP request. Swift-facing (`URL` / `Data` / header map) — the JS
/// wire form (base64 body, string map) is translated by `NetPlugin`; Swift
/// callers such as the remote AI providers build this directly.
public struct NetRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    /// Per-request timeout in seconds.
    public var timeout: TimeInterval

    public init(
        method: String = "GET",
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 60
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

/// A unary HTTP response. `status` and `body` are always present; a transport
/// failure surfaces as a thrown `BridgeError` instead of a response.
public struct NetResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Whether `status` is in the 2xx success range.
    public var isSuccess: Bool {
        (200 ..< 300).contains(status)
    }
}

/// A streaming download request. Writes `url` to `destination`, optionally
/// sending `headers` (auth, etc.) and verifying `sha256` on completion.
public struct NetDownloadRequest: Sendable, Equatable {
    public var url: URL
    public var destination: URL
    public var headers: [String: String]
    /// Lowercase hex SHA-256 to verify the downloaded bytes against; `nil`
    /// skips verification.
    public var sha256: String?

    public init(url: URL, destination: URL, headers: [String: String] = [:], sha256: String? = nil) {
        self.url = url
        self.destination = destination
        self.headers = headers
        self.sha256 = sha256
    }
}

/// One frame of a streaming download — a run of `progress` events, then a
/// terminal `done` carrying the written file path. Tagged the same way as the
/// other streaming events (`AIDownloadEvent` / `FsExtractEvent`).
public struct NetDownloadEvent: Sendable, Equatable {
    /// `"progress"` or `"done"`.
    public let type: String
    public let bytesDownloaded: Int64?
    /// Total bytes when the server sent a `Content-Length`; else `nil`.
    public let totalBytes: Int64?
    /// The written file path (on `done`).
    public let path: String?

    public init(type: String, bytesDownloaded: Int64? = nil, totalBytes: Int64? = nil, path: String? = nil) {
        self.type = type
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.path = path
    }

    public static func progress(bytesDownloaded: Int64, totalBytes: Int64?) -> NetDownloadEvent {
        NetDownloadEvent(type: "progress", bytesDownloaded: bytesDownloaded, totalBytes: totalBytes)
    }

    public static func done(path: String) -> NetDownloadEvent {
        NetDownloadEvent(type: "done", path: path)
    }
}

/// A receive-only WebSocket connection request. `url` is a `ws://` / `wss://`
/// origin; `headers` ride the opening handshake (auth, etc.).
public struct NetWebSocketRequest: Sendable, Equatable {
    public var url: URL
    public var headers: [String: String]

    public init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }
}

/// An inbound WebSocket frame.
public enum NetWebSocketEvent: Sendable, Equatable {
    case text(String)
    case binary(Data)
}
