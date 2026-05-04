#if canImport(WebKit) && (os(macOS) || os(iOS))
    import Foundation
    import SwiftPWACore
    import WebKit

    /// Bridges a `WKWebView` to the cross-platform `WebView` protocol.
    ///
    /// Owns:
    ///   - the `WKWebView` itself,
    ///   - a `WKScriptMessageHandler` registered as `__SwiftPWA__post`,
    ///   - the inbound frame `AsyncStream` consumed by `BridgeRuntime`,
    ///   - injection of `bridge.js` at document start.
    @MainActor
    public final class WKWebViewAdapter: NSObject, PWAWebView, WKScriptMessageHandler {
        public let webView: WKWebView
        private var assetProvider: AssetProvider?
        private var continuation: AsyncStream<InboundFrame>.Continuation?
        private lazy var stream: AsyncStream<InboundFrame> = AsyncStream { c in self.continuation = c }

        public init(configuration: WKWebViewConfiguration? = nil) throws {
            let cfg = configuration ?? WKWebViewConfiguration()
            // Inject bridge.js at document start.
            let bridge = try BridgeScript.source()
            let userScript = WKUserScript(
                source: bridge,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            cfg.userContentController.addUserScript(userScript)
            webView = WKWebView(frame: .zero, configuration: cfg)
            super.init()
            cfg.userContentController.add(self, name: BridgeScript.messageHandlerName)
            #if os(macOS)
                if #available(macOS 13.3, *) { webView.isInspectable = true }
            #else
                if #available(iOS 16.4, *) { webView.isInspectable = true }
            #endif
        }

        /// Register a `pwa://` scheme handler against this configuration.
        /// Must be called *before* the `WKWebView` is created if you
        /// want it to apply (because `WKWebViewConfiguration` is copied).
        public static func registerScheme(
            _ scheme: String,
            on configuration: WKWebViewConfiguration,
            assetProvider: AssetProvider
        ) {
            let handler = WKSchemeHandler(provider: assetProvider)
            configuration.setURLSchemeHandler(handler, forURLScheme: scheme)
        }

        public func attachAssetProvider(_ provider: AssetProvider) {
            assetProvider = provider
        }

        // MARK: - WebView

        public func load(_ content: WindowContent) {
            switch content {
            case let .bundled(directory, entry):
                attachAssetProvider(AssetProvider(root: directory))
                let url = URL(string: "pwa://localhost/\(entry)")!
                webView.load(URLRequest(url: url))
            case let .remote(url):
                webView.load(URLRequest(url: url))
            }
        }

        public func evaluateJavaScript(_ js: String) async throws -> String? {
            try await withCheckedThrowingContinuation { cont in
                webView.evaluateJavaScript(js) { value, error in
                    if let error { cont.resume(throwing: error); return }
                    if let value { cont.resume(returning: String(describing: value)) }
                    else { cont.resume(returning: nil) }
                }
            }
        }

        public func deliver(_ frame: OutboundFrame) async throws {
            let data = try Envelope.encode(frame)
            guard let json = String(data: data, encoding: .utf8) else {
                throw BridgeError(code: BridgeError.encode, message: "frame is not valid UTF-8")
            }
            // Use String literal escaping via JSONSerialization to be safe.
            let escaped = try jsString(json)
            let snippet = "globalThis.\(BridgeScript.globalName)?.__deliver(\(escaped));"
            _ = try await evaluateJavaScript(snippet)
        }

        public func inboundFrames() -> AsyncStream<InboundFrame> {
            _ = stream // ensure continuation is captured
            return stream
        }

        // MARK: - WKScriptMessageHandler

        public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == BridgeScript.messageHandlerName else { return }
            // Frames arrive as JSON strings (we deliberately don't trust
            // arbitrary JS objects; the JS side stringifies before posting).
            guard let body = message.body as? String else { return }
            guard let data = body.data(using: .utf8) else { return }
            do {
                let frame = try Envelope.decode(data)
                _ = stream
                continuation?.yield(frame)
            } catch {
                // Drop malformed frames silently — they cannot be replied to.
                #if DEBUG
                    print("swift-pwa: dropping malformed inbound frame: \(error)")
                #endif
            }
        }

        deinit {
            continuation?.finish()
        }
    }

    /// Encode a String as a JS string literal, e.g. `"foo\nbar"`.
    private func jsString(_ s: String) throws -> String {
        let data = try JSONEncoder().encode(s)
        guard let out = String(data: data, encoding: .utf8) else {
            throw BridgeError(code: BridgeError.encode, message: "failed to encode JS string")
        }
        return out
    }
#endif
