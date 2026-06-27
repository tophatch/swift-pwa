import Foundation
import SwiftPWACore

#if canImport(FoundationNetworking)
    import FoundationNetworking // URLSession / URLRequest live here on non-Apple platforms
#endif

#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

/// A model file to make available on disk: where to fetch it, what it
/// should hash to, and the filename to cache it under.
public struct ModelSpec: Sendable, Equatable {
    /// Remote URL to download from.
    public let url: URL
    /// Expected SHA-256, lowercase hex. `nil` skips integrity verification
    /// (not recommended for untrusted sources).
    public let sha256: String?
    /// Filename to cache under, inside the downloader's directory.
    public let fileName: String

    public init(url: URL, sha256: String? = nil, fileName: String) {
        self.url = url
        self.sha256 = sha256?.lowercased()
        self.fileName = fileName
    }
}

/// Resumable, checksum-pinned downloader behind `ai.ensureModel`. The
/// reusable half of the downloadable-model tier: a backend that ships a
/// downloadable model (llama.cpp, the Gemma fallback) keeps a registry of
/// `ModelSpec`s and calls this from its `AIBackend.ensureModel`.
///
/// Behavior:
/// - **Cache reuse** — if the cached file is present and (when a checksum
///   is given) matches, returns it immediately without a network call.
/// - **Resumable** — an interrupted download leaves a `.part` file; the
///   next call resumes it with an HTTP `Range` request (restarting only if
///   the server ignores the range).
/// - **Atomic** — bytes land in `<file>.part`, are checksum-verified, then
///   renamed into place, so a half-written file is never seen as ready.
/// - **Progress** — `onProgress(bytesDone, totalBytes?)` after each buffer
///   flush (`totalBytes` is `nil` when the server sends no length).
///
/// The network download path is **cross-platform**: Apple streams via
/// `URLSession.bytes(for:)`; Linux/Windows (swift-corelibs-foundation, which
/// doesn't ship `bytes(for:)`) get the same streamed, resumable,
/// progress-reporting download through a `URLSessionDataDelegate` that writes
/// each delivered body chunk to the `.part` file. Cache reuse, the `Range`
/// resume, checksum verification, and the API are identical on every platform.
public struct ModelDownloader: Sendable {
    /// Directory the models are cached in (created on demand). Typically a
    /// subdirectory of the app's data directory.
    public let directory: URL
    private let session: URLSession

    public init(directory: URL, session: URLSession = .shared) {
        self.directory = directory
        self.session = session
    }

    /// The on-disk location a spec resolves to (whether or not present yet).
    public func localURL(for spec: ModelSpec) -> URL {
        directory.appendingPathComponent(spec.fileName)
    }

    /// Ensure the model is present and (if pinned) intact, downloading or
    /// resuming as needed. Returns the local file URL.
    @discardableResult
    public func ensure(
        _ spec: ModelSpec,
        onProgress: (@Sendable (Int64, Int64?) -> Void)? = nil
    ) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let final = localURL(for: spec)

        if fm.fileExists(atPath: final.path) {
            if let want = spec.sha256 {
                if try await sha256Hex(of: final) == want { return final }
                try? fm.removeItem(at: final) // stale/corrupt — re-fetch
            } else {
                return final
            }
        }

        let part = final.appendingPathExtension("part")
        try await download(spec, to: part, onProgress: onProgress)

        if let want = spec.sha256 {
            let got = try await sha256Hex(of: part)
            guard got == want else {
                try? fm.removeItem(at: part)
                throw AIError.modelDownloadFailed("checksum mismatch (expected \(want), got \(got))")
            }
        }

        try? fm.removeItem(at: final)
        try fm.moveItem(at: part, to: final)
        return final
    }

    /// `ensure` adapted to the `AIBackend.ensureModel` shape — emits
    /// `AIDownloadEvent` progress frames, then a terminal `done`.
    public func events(for spec: ModelSpec) -> AsyncThrowingStream<AIDownloadEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await ensure(spec) { bytesDone, totalBytes in
                        continuation.yield(.progress(bytesDone: bytesDone, totalBytes: totalBytes))
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch let error as AIError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: AIError.modelDownloadFailed("\(error)"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Download

    private func download(
        _ spec: ModelSpec,
        to part: URL,
        onProgress: (@Sendable (Int64, Int64?) -> Void)?
    ) async throws {
        let fm = FileManager.default
        var offset: Int64 = 0
        if let size = (try? fm.attributesOfItem(atPath: part.path))?[.size] as? Int64 { offset = size }

        var request = URLRequest(url: spec.url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }

        #if canImport(Darwin)
            // Apple ships `URLSession.bytes(for:)`, so we stream the body
            // directly and buffer it to disk in 1 MiB flushes.
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AIError.modelDownloadFailed("no HTTP response from \(spec.url)")
            }
            guard (200 ... 299).contains(http.statusCode) else {
                throw AIError.modelDownloadFailed("download failed (HTTP \(http.statusCode))")
            }
            // Range honored → 206 Partial Content; a plain 200 means the server
            // ignored it, so discard the stale partial and restart from zero.
            if offset > 0, http.statusCode != 206 {
                try? fm.removeItem(at: part)
                offset = 0
            }

            // `expectedContentLength` is the remaining length for a 206.
            let total: Int64? = http.expectedContentLength >= 0 ? offset + http.expectedContentLength : nil

            if !fm.fileExists(atPath: part.path) { _ = fm.createFile(atPath: part.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: part)
            defer { try? handle.close() }
            try handle.seekToEnd()

            var done = offset
            var buffer = Data()
            buffer.reserveCapacity(1 << 20)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= (1 << 20) {
                    try handle.write(contentsOf: buffer)
                    done += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    onProgress?(done, total)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                done += Int64(buffer.count)
                onProgress?(done, total)
            }
        #else
            // swift-corelibs-foundation has no `bytes(for:)`, but a `dataTask`
            // still delivers its body incrementally through a
            // `URLSessionDataDelegate` — so we get the identical streamed,
            // resumable, progress-reporting download by writing each delivered
            // chunk to the `.part` file ourselves.
            let collector = ModelDownloadCollector(part: part, startOffset: offset, onProgress: onProgress)
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1 // delegate callbacks stay serial
            // Build the delegate-bearing session from the injected session's
            // *configuration* (a delegate can only be set at init): this carries
            // over caller config such as `protocolClasses` — so an injected mock
            // transport still applies, keeping the path unit-testable.
            let delegateSession = URLSession(
                configuration: session.configuration, delegate: collector, delegateQueue: queue
            )
            defer { delegateSession.finishTasksAndInvalidate() }

            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                    let task = delegateSession.dataTask(with: request)
                    collector.start(task: task, continuation: cont)
                }
            } onCancel: {
                collector.cancel()
            }
        #endif
    }

    // MARK: - Hashing

    /// Stream the file through SHA-256 so a multi-GB model isn't read into
    /// memory at once.
    private func sha256Hex(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while case let chunk = try handle.read(upToCount: 1 << 20), let data = chunk, !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

#if !canImport(Darwin)
    /// Drives a streamed, resumable model download on swift-corelibs-foundation,
    /// which lacks `URLSession.bytes(for:)`. The session delivers the body
    /// through `URLSessionDataDelegate` callbacks (serial on the delegate
    /// queue), each of which we write straight to the `.part` file — matching
    /// the Apple `bytes(for:)` path's behavior (Range resume, 200-restart,
    /// progress). `@unchecked Sendable`: the delegate callbacks are serialized
    /// by the single-concurrency delegate queue, and the lock guards the
    /// continuation/task hand-off against the cancellation path.
    private final class ModelDownloadCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let part: URL
        private let startOffset: Int64
        private let onProgress: (@Sendable (Int64, Int64?) -> Void)?

        private var handle: FileHandle?
        private var done: Int64
        private var total: Int64?

        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, any Error>?
        private var task: URLSessionTask?
        private var finished = false

        init(part: URL, startOffset: Int64, onProgress: (@Sendable (Int64, Int64?) -> Void)?) {
            self.part = part
            self.startOffset = startOffset
            done = startOffset
            self.onProgress = onProgress
        }

        /// Resume the data task and remember the continuation to fulfill when it
        /// completes. Called once, before any delegate callback can fire.
        func start(task: URLSessionTask, continuation: CheckedContinuation<Void, any Error>) {
            lock.lock()
            self.task = task
            self.continuation = continuation
            lock.unlock()
            task.resume()
        }

        func cancel() {
            lock.lock()
            let t = task
            lock.unlock()
            t?.cancel() // surfaces as didComplete(error:) → finish(.failure)
        }

        private func finish(_ result: Result<Void, any Error>) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let cont = continuation
            continuation = nil
            lock.unlock()
            try? handle?.close()
            cont?.resume(with: result)
        }

        // MARK: URLSessionDataDelegate

        func urlSession(
            _: URLSession,
            dataTask _: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse else {
                finish(.failure(AIError.modelDownloadFailed("no HTTP response from \(part.lastPathComponent)")))
                completionHandler(.cancel)
                return
            }
            guard (200 ... 299).contains(http.statusCode) else {
                finish(.failure(AIError.modelDownloadFailed("download failed (HTTP \(http.statusCode))")))
                completionHandler(.cancel)
                return
            }

            let fm = FileManager.default
            var effectiveOffset = startOffset
            // Range honored → 206; a plain 200 means the server ignored it, so
            // discard the stale partial and restart from zero.
            if startOffset > 0, http.statusCode != 206 {
                try? fm.removeItem(at: part)
                effectiveOffset = 0
                done = 0
            }
            total = http.expectedContentLength >= 0 ? effectiveOffset + http.expectedContentLength : nil

            if !fm.fileExists(atPath: part.path) { _ = fm.createFile(atPath: part.path, contents: nil) }
            do {
                let h = try FileHandle(forWritingTo: part)
                try h.seekToEnd() // 0 for a fresh/restarted file, the resume offset for a 206
                handle = h
                completionHandler(.allow)
            } catch {
                finish(.failure(error))
                completionHandler(.cancel)
            }
        }

        func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let handle else { return }
            do {
                try handle.write(contentsOf: data)
                done += Int64(data.count)
                onProgress?(done, total)
            } catch {
                finish(.failure(error))
                dataTask.cancel()
            }
        }

        func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
            if let error {
                finish(.failure(AIError.modelDownloadFailed("\(error)")))
            } else {
                finish(.success(()))
            }
        }
    }
#endif
