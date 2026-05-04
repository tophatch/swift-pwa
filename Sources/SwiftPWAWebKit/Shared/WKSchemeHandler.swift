#if canImport(WebKit) && (os(macOS) || os(iOS))
    import Foundation
    import SwiftPWACore
    import WebKit

    /// `WKURLSchemeHandler` implementation for `pwa://localhost/...` URLs.
    /// Backs them with an `AssetProvider` rooted at the bundled web folder.
    ///
    /// WebKit calls `start`/`stop` on the main thread but the protocol
    /// itself is not actor-isolated, so this class lives outside any
    /// actor and reads files synchronously — fine for typical bundle
    /// sizes and avoids WKURLSchemeTask sendability headaches.
    public final class WKSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
        private let provider: AssetProvider

        public init(provider: AssetProvider) {
            self.provider = provider
        }

        public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url,
                  let resolved = provider.resolve(url)
            else {
                let url = urlSchemeTask.request.url
                urlSchemeTask.didFailWithError(NSError(
                    domain: "swift-pwa",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "not found: \(url?.absoluteString ?? "<nil>")"]
                ))
                return
            }
            do {
                let data = try Data(contentsOf: resolved.fileURL)
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": resolved.mimeType,
                        "Content-Length": String(data.count),
                        "Access-Control-Allow-Origin": "*",
                    ]
                )!
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                urlSchemeTask.didFailWithError(error)
            }
        }

        public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
            // Synchronous handler — nothing to cancel.
        }
    }
#endif
