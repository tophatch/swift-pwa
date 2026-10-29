#if canImport(WebKit) && (os(macOS) || os(iOS))
    import Foundation
    import SwiftPWACore
    import WebKit

    /// `WKURLSchemeHandler` for `pwa://localhost/...` URLs, backed by an
    /// `AssetProvider` (the mount table rooted at the bundle + any served
    /// directories).
    ///
    /// Honors HTTP `Range` requests (`206 Partial Content`), so a large
    /// served `.webm` from an imported content pack seeks/streams instead of
    /// buffering: it reads only the requested byte range, in chunks, so the
    /// whole file never lands in memory.
    ///
    /// The file work — resolve, open, seek, read — runs on a concurrent
    /// queue, never the main thread. A file's bytes aren't always on local
    /// disk: an iCloud Drive (or any File Provider) placeholder has a real name
    /// and size and no bytes, so reading it *is* downloading it, and a network
    /// volume is no better. Read on the main thread, that froze the app — bridge
    /// replies, `drive` verbs, an iPad rotation — for as long as the download
    /// took, and every other request queued behind it (#338). Only delivery to
    /// the `WKURLSchemeTask` hops to the main thread, one chunk at a time, so a
    /// read never runs more than a chunk ahead of WebKit and memory stays
    /// bounded.
    public final class WKSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
        private let provider: AssetProvider
        private static let chunkSize = 256 * 1024
        private let queue = DispatchQueue(
            label: "swift-pwa.scheme-handler", qos: .userInitiated, attributes: .concurrent
        )

        /// The tasks being served, by a token the worker carries instead of
        /// the task (which isn't `Sendable`). Main thread only. A task leaves
        /// when it finishes or WebKit stops it, and WebKit raises an exception
        /// if a stopped task is messaged, so a worker whose token is gone stops
        /// reading and delivers nothing more. A counter, not the task's object
        /// identity: a stopped task's address can be reused by the next one.
        private var tasks: [UInt64: any WKURLSchemeTask] = [:]
        private var nextToken: UInt64 = 0

        public init(provider: AssetProvider) {
            self.provider = provider
        }

        public func webView(_: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            nextToken += 1
            let token = nextToken
            tasks[token] = urlSchemeTask
            let request = urlSchemeTask.request
            queue.async { [self] in serve(request, token: token) }
        }

        public func webView(_: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
            tasks = tasks.filter { $0.value !== urlSchemeTask }
        }

        /// Runs on `queue`.
        private func serve(_ request: URLRequest, token: UInt64) {
            guard let url = request.url, let resolved = provider.resolve(url) else {
                let missing = request.url?.absoluteString ?? "<nil>"
                fail(token, NSError(
                    domain: "swift-pwa", code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "not found: \(missing)"]
                ))
                return
            }

            let resolution = ByteRange.resolve(
                header: request.value(forHTTPHeaderField: "Range"),
                fileSize: resolved.fileSize
            )

            // 416 for a range we can't satisfy.
            if case .unsatisfiable = resolution {
                let response = HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Range": "bytes */\(resolved.fileSize)",
                    "Access-Control-Allow-Origin": "*"
                ])!
                _ = deliver(token, ending: true) { $0.didReceive(response); $0.didFinish() }
                return
            }

            let status: Int
            let offset: Int64
            let length: Int64
            switch resolution {
            case .full: (status, offset, length) = (200, 0, resolved.fileSize)
            case let .partial(o, l): (status, offset, length) = (206, o, l)
            case .unsatisfiable: return // handled above
            }

            var headers = [
                "Content-Type": resolved.mimeType,
                "Content-Length": String(length),
                "Accept-Ranges": "bytes",
                "Access-Control-Allow-Origin": "*"
            ]
            if status == 206 {
                headers["Content-Range"] = "bytes \(offset)-\(offset + length - 1)/\(resolved.fileSize)"
            }

            do {
                let handle = try FileHandle(forReadingFrom: resolved.fileURL)
                defer { try? handle.close() }
                if offset > 0 { try handle.seek(toOffset: UInt64(offset)) }
                guard let response = HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
                ) else {
                    fail(token, NSError(domain: "swift-pwa", code: 500, userInfo: nil))
                    return
                }
                guard deliver(token, { $0.didReceive(response) }) else { return }

                var remaining = length
                while remaining > 0 {
                    let toRead = Int(min(Int64(Self.chunkSize), remaining))
                    guard let chunk = try handle.read(upToCount: toRead), !chunk.isEmpty else { break }
                    guard deliver(token, { $0.didReceive(chunk) }) else { return }
                    remaining -= Int64(chunk.count)
                }
                _ = deliver(token, ending: true) { $0.didFinish() }
            } catch {
                fail(token, error)
            }
        }

        private func fail(_ token: UInt64, _ error: any Error) {
            _ = deliver(token, ending: true) { $0.didFailWithError(error) }
        }

        /// Run `body` against the task on the main thread, and wait for it so
        /// the next chunk isn't read before this one is handed over. Returns
        /// false, without running `body`, once the task is stopped. `ending`
        /// retires the token: `body` finished or failed the task.
        private func deliver(
            _ token: UInt64,
            ending: Bool = false,
            _ body: @MainActor (any WKURLSchemeTask) -> Void
        ) -> Bool {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    guard let task = tasks[token] else { return false }
                    body(task)
                    if ending { tasks[token] = nil }
                    return true
                }
            }
        }
    }
#endif
