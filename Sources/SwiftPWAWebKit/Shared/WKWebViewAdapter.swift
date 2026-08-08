#if canImport(WebKit) && (os(macOS) || os(iOS))
    import Foundation
    import SwiftPWACore
    import WebKit

    /// Bridges a `WKWebView` to the cross-platform `WebView` protocol.
    ///
    /// **Threading**: not `@MainActor`. WKWebView calls are routed
    /// through `MainThread.run` so the same code paths work whether
    /// the caller is on the main actor or a cooperative-pool task.
    /// `WKScriptMessageHandler.userContentController(_:didReceive:)`
    /// is invoked on the main thread by WebKit; the continuation it
    /// writes to is intrinsically thread-safe.
    public final class WKWebViewAdapter: NSObject, PWAWebView, WKScriptMessageHandler, @unchecked Sendable {
        public nonisolated let webView: WKWebView
        private nonisolated(unsafe) var assetProvider: AssetProvider?
        private nonisolated(unsafe) var continuation: AsyncStream<InboundFrame>.Continuation?
        /// Eager `let` rather than a lazy var — Swift 6.0 (Xcode 16.4)
        /// refuses `nonisolated` on `lazy` properties, and dropping
        /// the modifier promotes `stream` to MainActor isolation
        /// (because the class participates in `WKScriptMessageHandler`),
        /// which then breaks `nonisolated func inboundFrames()`.
        /// `AsyncStream`'s initializer invokes the captured-continuation
        /// closure synchronously, so we can lift `continuation` out of
        /// it during init and assign it after `super.init`.
        /// `AsyncStream<InboundFrame>` is `Sendable`, so a plain
        /// `nonisolated let` suffices — no `(unsafe)`.
        private nonisolated let stream: AsyncStream<InboundFrame>

        public init(configuration: WKWebViewConfiguration? = nil) throws {
            var captured: AsyncStream<InboundFrame>.Continuation?
            stream = AsyncStream { captured = $0 }

            let cfg = configuration ?? WKWebViewConfiguration()
            // Let the app's own JS (first-party content from pwa://) play media
            // it generates — e.g. on-device TTS — without a user gesture.
            // Autoplay policies exist to tame untrusted web pages; for a
            // first-party wrapper they just break `audio.play()` (a long async
            // between the tap and playback drops the user-activation, so the
            // play is rejected and stays silent). Empty set = no media type
            // requires a gesture.
            cfg.mediaTypesRequiringUserActionForPlayback = []
            // Inject bridge.js at document start.
            let bridge = try BridgeScript.source()
            let userScript = WKUserScript(
                source: bridge,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            cfg.userContentController.addUserScript(userScript)
            #if os(macOS) && SWIFT_PWA_DRIVER
                webView = DriverWebView(frame: .zero, configuration: cfg)
            #else
                webView = WKWebView(frame: .zero, configuration: cfg)
            #endif
            super.init()
            continuation = captured
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

        /// `nonisolated` so `load` (which is also nonisolated for
        /// protocol conformance) can call it. The stored property is
        /// already `nonisolated(unsafe)`.
        public nonisolated func attachAssetProvider(_ provider: AssetProvider) {
            assetProvider = provider
        }

        // MARK: - PWAWebView

        // Marked `nonisolated` because the protocol requirements are
        // nonisolated; `NSObject` + `WKScriptMessageHandler` would
        // otherwise infer @MainActor.

        public nonisolated func load(_ content: WindowContent) {
            // Hop to MainActor: WKWebView APIs are MainActor-isolated.
            let webView = webView
            Task { @MainActor in
                switch content {
                case let .bundled(_, entry, _):
                    // `SWIFT_PWA_INITIAL_ROUTE` can send the first window
                    // somewhere other than the entry; the entry itself stays
                    // the SPA-fallback document.
                    let path = InitialRoute.take(declared: entry)
                    guard let url = URL(string: "pwa://localhost/\(path)") else {
                        FileHandle.standardError.writeQuietly(Data(
                            "swift-pwa: '\(path)' isn't a loadable bundle path\n".utf8
                        ))
                        return
                    }
                    webView.load(URLRequest(url: url))
                case let .remote(url):
                    webView.load(URLRequest(url: url))
                }
            }
            if case let .bundled(directory, _, _) = content {
                attachAssetProvider(AssetProvider(root: directory))
            }
        }

        public nonisolated func evaluateJavaScript(_ js: String) async throws -> String? {
            try await evaluateOnMain(js)
        }

        /// Runs on the MainActor so WKWebView's `@MainActor` async
        /// `evaluateJavaScript` — and the `String`→`NSString` bridging of
        /// its argument — happen there, rather than being *sent* across the
        /// isolation boundary (which Swift 6 flags as a data-race risk). The
        /// non-`Sendable` `Any?` result is reduced to a `Sendable` `String?`
        /// here too, so only `Sendable` values cross back out. A `nil` result
        /// means `undefined`/no value — the common case for the `deliver`
        /// snippets, which evaluate to `undefined`.
        @MainActor private func evaluateOnMain(_ js: String) async throws -> String? {
            let value: Any? = try await webView.evaluateJavaScript(js)
            guard let value, !(value is NSNull) else { return nil }
            // WKWebView hands back a bridged Objective-C object graph, not
            // JSON. `String(describing:)` of that is Swift's *debug*
            // description — `1` for a JS `true`, an unparseable dump for an
            // object — whereas the protocol (and WebKitGTK's
            // `jsc_value_to_json`) promise a JSON serialization. Serialize
            // properly so the contract holds on Apple too, and fall back to
            // the description for the rare value JSON can't represent.
            if let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed]
            ), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return String(describing: value)
        }

        public nonisolated func deliver(_ frame: OutboundFrame) async throws {
            let data = try Envelope.encode(frame)
            guard let json = String(data: data, encoding: .utf8) else {
                throw BridgeError(code: BridgeError.encode, message: "frame is not valid UTF-8")
            }
            let escaped = try jsString(json)
            let snippet = "globalThis.\(BridgeScript.globalName)?.__deliver(\(escaped));"
            _ = try await evaluateJavaScript(snippet)
        }

        public nonisolated func inboundFrames() -> AsyncStream<InboundFrame> {
            _ = stream // ensure continuation is captured
            return stream
        }

        // MARK: - Snapshot

        public nonisolated var supportsSnapshot: Bool {
            true
        }

        /// `WKWebView.takeSnapshot` renders through WebKit's own compositor
        /// rather than reading the framebuffer, which is the whole reason the
        /// driver can screenshot an app that is backgrounded, occluded or on
        /// another Space — and without the Screen Recording TCC grant that
        /// `CGWindowListCreateImage` / `screencapture` demand.
        public nonisolated func captureSnapshot() async throws -> Data {
            try await snapshotOnMain()
        }

        @MainActor private func snapshotOnMain() async throws -> Data {
            let config = WKSnapshotConfiguration()
            // Flush pending layout/paint first, so a snapshot taken right
            // after an `eval` that mutated the DOM shows the mutation.
            config.afterScreenUpdates = true
            let image = try await webView.takeSnapshot(configuration: config)
            guard let png = Self.encodePNG(image) else {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "couldn't PNG-encode the webview snapshot"
                )
            }
            return png
        }

        #if os(macOS)
            @MainActor private static func encodePNG(_ image: NSImage) -> Data? {
                // Via CGImage rather than `tiffRepresentation` so the output
                // keeps the backing store's pixel dimensions — on a Retina
                // display an `NSImage`'s point size is half of them.
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                else { return nil }
                return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
            }
        #else
            @MainActor private static func encodePNG(_ image: UIImage) -> Data? {
                image.pngData()
            }
        #endif

        public nonisolated func openDevTools() {
            #if os(macOS)
                // WKWebView responds to the private `_showInspector:`
                // selector when `isInspectable = true` is set (we set
                // it during init). Best-effort SPI — guard on
                // `responds(to:)` so a future runtime change just
                // logs a hint rather than crashing.
                let webView = webView
                Task { @MainActor in
                    let sel = NSSelectorFromString("_showInspector:")
                    if webView.responds(to: sel) {
                        webView.perform(sel, with: nil)
                    } else {
                        FileHandle.standardError.writeQuietly(Data("""
                        swift-pwa: WKWebView doesn't respond to _showInspector: on this macOS build.
                        Use Safari's Develop menu (Develop > Open Web Inspector) instead.

                        """.utf8))
                    }
                }
            #endif
            // iOS: WKWebView doesn't ship a programmatic inspector
            // opener at all — debug from Safari on a paired Mac
            // (Develop > <device> > <page>).
        }

        // MARK: - WKScriptMessageHandler

        public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == BridgeScript.messageHandlerName else { return }
            guard let body = message.body as? String else { return }
            guard let data = body.data(using: .utf8) else { return }
            do {
                let frame = try Envelope.decode(data)
                _ = stream
                continuation?.yield(frame)
            } catch {
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
