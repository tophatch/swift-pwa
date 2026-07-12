import Foundation

#if canImport(FoundationNetworking)
    // swift-corelibs-foundation (Linux + Windows) ships URLSession / URLRequest
    // via a separate module — same conditional import the updater backends and
    // bundlers use. Without it URLSession isn't visible on those platforms.
    import FoundationNetworking
#endif

#if canImport(CryptoKit)
    import CryptoKit
#elseif canImport(Crypto)
    import Crypto
#endif

/// The `NetworkClient` for every platform whose `URLSession` works with the
/// system CA store — Apple, Linux, and Windows. (Android is the exception, and
/// uses `AndroidNetworkClient` over the Kotlin RPC bridge; see that type.)
///
/// `send` bridges `URLSession.dataTask`'s completion handler into an
/// `async` call — the completion-handler form rather than the async
/// `data(for:)` overload, because the latter is unreliable on
/// swift-corelibs-foundation (the same reason `ModelDownloader` streams via a
/// delegate on Linux/Windows). `download` wraps a `URLSessionDownloadDelegate`
/// so a long transfer reports fine-grained progress, mirroring
/// `UpdaterDownload`.
public struct URLSessionNetworkClient: NetworkClient {
    private let configuration: URLSessionConfiguration

    /// - Parameter configuration: used for `send` (via a shared session) and as
    ///   the template for the per-download delegate session. Defaults to
    ///   `.default`; tests pass a configuration with mock `URLProtocol` classes.
    public init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: - Unary

    public func send(_ request: NetRequest) async throws -> NetResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        for (field, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: field) }
        urlRequest.httpBody = request.body

        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: urlRequest) { data, response, error in
                if let error {
                    continuation.resume(throwing: BridgeError(
                        code: BridgeError.net,
                        message: "request failed: \(error.localizedDescription)"
                    ))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: BridgeError(
                        code: BridgeError.net,
                        message: "no HTTP response from \(request.url.absoluteString)"
                    ))
                    return
                }
                continuation.resume(returning: NetResponse(
                    status: http.statusCode,
                    headers: Self.headerMap(http),
                    body: data ?? Data()
                ))
            }
            task.resume()
        }
    }

    // MARK: - Streaming download

    public func download(_ request: NetDownloadRequest) -> AsyncThrowingStream<NetDownloadEvent, any Error> {
        AsyncThrowingStream { continuation in
            var urlRequest = URLRequest(url: request.url)
            for (field, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: field) }

            let delegate = NetDownloadDelegate(
                destination: request.destination,
                sha256: request.sha256?.lowercased(),
                continuation: continuation
            )
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            continuation.onTermination = { _ in session.invalidateAndCancel() }
            session.downloadTask(with: urlRequest).resume()
        }
    }

    /// Flatten `HTTPURLResponse.allHeaderFields` (an `[AnyHashable: Any]`) to a
    /// `[String: String]`, dropping any non-string pairs.
    private static func headerMap(_ http: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return headers
    }
}

/// Delegate driving `URLSessionNetworkClient.download`. Turns the download
/// task's periodic `didWriteData` callbacks into `progress` yields, moves the
/// finished temp file to the destination synchronously (URLSession deletes it
/// as soon as `didFinishDownloadingTo` returns), verifies the checksum, then
/// yields `done`. `@unchecked Sendable`: URLSession serializes its callbacks on
/// one delegate queue, so the mutable state is effectively single-threaded.
private final class NetDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let sha256: String?
    private let continuation: AsyncThrowingStream<NetDownloadEvent, any Error>.Continuation
    private var moveError: (any Error)?

    init(
        destination: URL,
        sha256: String?,
        continuation: AsyncThrowingStream<NetDownloadEvent, any Error>.Continuation
    ) {
        self.destination = destination
        self.sha256 = sha256
        self.continuation = continuation
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        continuation.yield(.progress(bytesDownloaded: totalBytesWritten, totalBytes: total))
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Must move synchronously — URLSession removes the temp file when this
        // returns. Stash any failure for `didCompleteWithError` to surface.
        do {
            try? FileManager.default.removeItem(at: destination)
            let parent = destination.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            continuation.finish(throwing: BridgeError(
                code: BridgeError.net,
                message: "download failed: \(error.localizedDescription)"
            ))
            return
        }
        if let moveError {
            continuation.finish(throwing: BridgeError(
                code: BridgeError.net,
                message: "staging downloaded file failed: \(moveError.localizedDescription)"
            ))
            return
        }
        if let http = task.response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            continuation.finish(throwing: BridgeError(
                code: BridgeError.net,
                message: "download returned HTTP \(http.statusCode)"
            ))
            return
        }
        if let want = sha256 {
            do {
                let got = try Self.sha256Hex(of: destination)
                guard got == want else {
                    continuation.finish(throwing: BridgeError(
                        code: BridgeError.net,
                        message: "checksum mismatch: expected \(want), got \(got)"
                    ))
                    return
                }
            } catch {
                continuation.finish(throwing: BridgeError(
                    code: BridgeError.net,
                    message: "checksum verification failed: \(error.localizedDescription)"
                ))
                return
            }
        }
        continuation.yield(.done(path: destination.path))
        continuation.finish()
    }

    /// Stream the file through SHA-256 so a large download isn't read into
    /// memory at once. Available where a crypto module is linked (Apple's
    /// CryptoKit / swift-crypto on Linux); on a platform with neither, a
    /// requested checksum is a hard error rather than a silent skip.
    private static func sha256Hex(of url: URL) throws -> String {
        #if canImport(CryptoKit) || canImport(Crypto)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
            throw BridgeError(
                code: BridgeError.net,
                message: "sha256 verification is unavailable on this platform"
            )
        #endif
    }
}
