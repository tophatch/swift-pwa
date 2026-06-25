#if canImport(WebKit) && (os(macOS) || os(iOS))
    import Foundation
    import SwiftPWACore
    import WebKit

    /// `WKURLSchemeHandler` for `pwa://localhost/...` URLs, backed by an
    /// `AssetProvider` (the mount table rooted at the bundle + any served
    /// directories).
    ///
    /// Streams responses in chunks off the main thread and honors HTTP
    /// `Range` requests (`206 Partial Content`), so a large served `.webm`
    /// from an imported content pack seeks/streams instead of buffering
    /// fully — and the UI thread isn't blocked reading it. WebKit calls
    /// `start`/`stop` on the main thread; the actual file read runs on a
    /// background queue, with a cancellation set keyed by task identity.
    public final class WKSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
        private let provider: AssetProvider
        private let queue = DispatchQueue(label: "dev.swiftpwa.scheme", qos: .userInitiated, attributes: .concurrent)
        private let lock = NSLock()
        private var cancelled = Set<ObjectIdentifier>()
        private static let chunkSize = 256 * 1024

        public init(provider: AssetProvider) {
            self.provider = provider
        }

        public func webView(_: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url, let resolved = provider.resolve(url) else {
                let missing = urlSchemeTask.request.url?.absoluteString ?? "<nil>"
                urlSchemeTask.didFailWithError(NSError(
                    domain: "swift-pwa", code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "not found: \(missing)"]
                ))
                return
            }

            let resolution = ByteRange.resolve(
                header: urlSchemeTask.request.value(forHTTPHeaderField: "Range"),
                fileSize: resolved.fileSize
            )
            let id = ObjectIdentifier(urlSchemeTask as AnyObject)
            let box = TaskBox(urlSchemeTask)

            queue.async { [weak self] in
                guard let self else { return }
                serve(box: box, id: id, url: url, resolved: resolved, resolution: resolution)
            }
        }

        public func webView(_: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
            let id = ObjectIdentifier(urlSchemeTask as AnyObject)
            lock.lock(); cancelled.insert(id); lock.unlock()
        }

        // MARK: - Streaming

        private func serve(
            box: TaskBox,
            id: ObjectIdentifier,
            url: URL,
            resolved: AssetProvider.Resolved,
            resolution: ByteRangeResolution
        ) {
            let task = box.task

            // 416 for an unsatisfiable range.
            if case .unsatisfiable = resolution {
                guard !isCancelled(id) else { return }
                let response = HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Range": "bytes */\(resolved.fileSize)",
                    "Access-Control-Allow-Origin": "*"
                ])!
                task.didReceive(response)
                task.didFinish()
                clear(id)
                return
            }

            let status: Int
            let offset: Int64
            let length: Int64
            switch resolution {
            case .full: (status, offset, length) = (200, 0, resolved.fileSize)
            case let .partial(o, l): (status, offset, length) = (206, o, l)
            case .unsatisfiable: return
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

            guard let handle = try? FileHandle(forReadingFrom: resolved.fileURL) else {
                if !isCancelled(id) {
                    task.didFailWithError(NSError(domain: "swift-pwa", code: 404, userInfo: nil))
                }
                clear(id)
                return
            }
            defer { try? handle.close() }

            do {
                if offset > 0 { try handle.seek(toOffset: UInt64(offset)) }
            } catch {
                if !isCancelled(id) { task.didFailWithError(error) }
                clear(id)
                return
            }

            guard !isCancelled(id),
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: status,
                      httpVersion: "HTTP/1.1",
                      headerFields: headers
                  )
            else { clear(id); return }
            task.didReceive(response)

            var remaining = length
            while remaining > 0 {
                if isCancelled(id) { clear(id); return }
                let toRead = Int(min(Int64(Self.chunkSize), remaining))
                guard let chunk = try? handle.read(upToCount: toRead), !chunk.isEmpty else { break }
                if isCancelled(id) { clear(id); return }
                task.didReceive(chunk)
                remaining -= Int64(chunk.count)
            }
            if !isCancelled(id) { task.didFinish() }
            clear(id)
        }

        private func isCancelled(_ id: ObjectIdentifier) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled.contains(id)
        }

        private func clear(_ id: ObjectIdentifier) {
            lock.lock(); defer { lock.unlock() }
            cancelled.remove(id)
        }
    }

    /// Carries the non-`Sendable` `WKURLSchemeTask` across the hop to the
    /// background queue. The handler serializes all use of the task (one
    /// serving closure per task, guarded by the cancellation set), so this
    /// `@unchecked` is sound in practice.
    private final class TaskBox: @unchecked Sendable {
        let task: any WKURLSchemeTask
        init(_ task: any WKURLSchemeTask) { self.task = task }
    }
#endif
