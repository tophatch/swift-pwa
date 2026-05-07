import Foundation

#if canImport(FoundationNetworking)
    // swift-corelibs-foundation (Linux + Windows) ships URLSession via a
    // separate module. The bundlers and updater backends each have this
    // same conditional import — without it, the URLSessionDownloadDelegate
    // protocol below isn't visible on those platforms.
    import FoundationNetworking
#endif

/// Streaming download helper shared by the three `Updater` backends.
///
/// Each backend used to call `urlSession.download(from:)` and emit a
/// single `(0, nil)` start frame plus a single end frame — the API
/// returns once and gives no progress mid-flight. The runtime contract
/// in `Updater.download` says "yields `downloadProgress` events while
/// bytes are streaming," and a UI showing a progress bar wants more
/// than two data points over a 50 MB download. This helper wraps a
/// `URLSessionDownloadDelegate` and turns its periodic `didWriteData`
/// callbacks into the fine-grained progress yields callers want.
///
/// ## How it works
///
/// We create a fresh `URLSession` with our delegate (the user-supplied
/// session is used only for its configuration — protocol classes,
/// timeouts, etc. — because a session's delegate is fixed at creation
/// time). The session retains the delegate until invalidated; we
/// `invalidateAndCancel()` in `defer` to break the cycle. The delegate
/// captures the destination URL up-front and moves the temp file
/// synchronously inside `didFinishDownloadingTo` (URLSession deletes
/// the temp file as soon as that callback returns), then signals the
/// awaiting continuation in `didCompleteWithError`.
///
/// ## Errors
///
/// Throws a `BridgeError(code: .handler)` for transport errors, non-2xx
/// HTTP responses, and rename / move failures during the temp-file
/// swap. The three backends already wrap their `download` body in a
/// `try/catch` that lets `BridgeError` pass through and rewraps
/// everything else, so this matches the existing convention.
public enum UpdaterDownload {
    /// Download `url` to `destination`, calling `onProgress` periodically
    /// during the transfer. The destination file is replaced
    /// (delete-then-move) on success.
    ///
    /// - Parameters:
    ///   - url: Artifact URL.
    ///   - destination: Where to put the downloaded file. Any existing
    ///     file at this path is removed first.
    ///   - urlSession: Used for its `.configuration` only — protocol
    ///     classes, timeouts, etc. propagate. Pass `.shared` for
    ///     production; tests pass a configured session with mock
    ///     `URLProtocol` classes.
    ///   - onProgress: Called from the `URLSession`'s delegate queue
    ///     (not the main thread) with `(bytesDownloaded,
    ///     totalContentLength?)`. `total` is `nil` when the server
    ///     didn't send a `Content-Length`. Called at least once at
    ///     start (`(0, total)`) and once at end (`(total, total)`).
    /// - Returns: The final `URLResponse` (so callers can inspect e.g.
    ///   `MIMEType`).
    public static func download(
        from url: URL,
        to destination: URL,
        urlSession: URLSession,
        onProgress: @escaping @Sendable (_ bytesDownloaded: Int, _ totalContentLength: Int?) -> Void
    ) async throws -> URLResponse {
        let delegate = StreamingDelegate(destination: destination, onProgress: onProgress)
        let session = URLSession(
            configuration: urlSession.configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        return try await delegate.run(in: session, url: url)
    }
}

/// Delegate for `UpdaterDownload`. Intentionally `final class` +
/// `@unchecked Sendable` — URLSession invokes its callbacks from a
/// single internal queue per session, so the mutable state below is
/// effectively single-threaded. Marking it `Sendable` lets us hand the
/// instance to `URLSession(configuration:delegate:delegateQueue:)` from
/// an `async` context without strict-concurrency complaints.
private final class StreamingDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Int, Int?) -> Void

    private var continuation: CheckedContinuation<URLResponse, any Error>?
    private var finalResponse: URLResponse?
    private var moveError: (any Error)?

    init(
        destination: URL,
        onProgress: @escaping @Sendable (Int, Int?) -> Void
    ) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func run(in session: URLSession, url: URL) async throws -> URLResponse {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            // Yield `(0, nil)` at start so subscribers get a frame
            // before bytes arrive — matches the contract the previous
            // two-shot implementation set.
            self.onProgress(0, nil)
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total: Int? = totalBytesExpectedToWrite > 0 ? Int(totalBytesExpectedToWrite) : nil
        onProgress(Int(totalBytesWritten), total)
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // URLSession deletes the temp file as soon as this method
        // returns, so the move *must* happen synchronously here. We
        // stash the response (and any error) for `didCompleteWithError`
        // to surface — the documented order is didFinish → didComplete
        // for successful tasks.
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finalResponse = downloadTask.response
        } catch {
            moveError = error
        }
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let cont = continuation else { return }
        continuation = nil

        if let error {
            cont.resume(throwing: BridgeError(
                code: BridgeError.handler,
                message: "artifact fetch failed: \(error.localizedDescription)"
            ))
            return
        }
        if let moveError {
            cont.resume(throwing: BridgeError(
                code: BridgeError.handler,
                message: "staging downloaded artifact failed: \(moveError.localizedDescription)"
            ))
            return
        }
        guard let response = finalResponse ?? task.response else {
            cont.resume(throwing: BridgeError(
                code: BridgeError.handler,
                message: "download completed without a response"
            ))
            return
        }
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            cont.resume(throwing: BridgeError(
                code: BridgeError.handler,
                message: "artifact fetch returned HTTP \(http.statusCode)"
            ))
            return
        }
        cont.resume(returning: response)
    }
}
