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
    /// whole file never lands in memory (the win over the previous
    /// `Data(contentsOf:)` full-file read). `WKURLSchemeHandler` is
    /// `@MainActor` in recent SDKs and `WKURLSchemeTask` isn't `Sendable`, so
    /// delivery stays on the main actor; chunked reads keep peak memory
    /// bounded. (Moving the file read off-thread is a possible later
    /// optimization, but needs care around the task's main-actor isolation.)
    public final class WKSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
        private let provider: AssetProvider
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

            // 416 for a range we can't satisfy.
            if case .unsatisfiable = resolution {
                let response = HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Range": "bytes */\(resolved.fileSize)",
                    "Access-Control-Allow-Origin": "*"
                ])!
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didFinish()
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
                    urlSchemeTask.didFailWithError(NSError(domain: "swift-pwa", code: 500, userInfo: nil))
                    return
                }
                urlSchemeTask.didReceive(response)

                // Deliver the requested range in chunks so peak memory is
                // bounded regardless of file size (a GB video never fully
                // materializes).
                var remaining = length
                while remaining > 0 {
                    let toRead = Int(min(Int64(Self.chunkSize), remaining))
                    guard let chunk = try handle.read(upToCount: toRead), !chunk.isEmpty else { break }
                    urlSchemeTask.didReceive(chunk)
                    remaining -= Int64(chunk.count)
                }
                urlSchemeTask.didFinish()
            } catch {
                urlSchemeTask.didFailWithError(error)
            }
        }

        public func webView(_: WKWebView, stop _: any WKURLSchemeTask) {
            // Delivery is synchronous within `start`, so there's nothing
            // in flight to cancel by the time `stop` is called.
        }
    }
#endif
