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
        private nonisolated(unsafe) var continuation: AsyncStream<InboundMessage>.Continuation?
        /// Eager `let` rather than a lazy var — Swift 6.0 (Xcode 16.4)
        /// refuses `nonisolated` on `lazy` properties, and dropping
        /// the modifier promotes `stream` to MainActor isolation
        /// (because the class participates in `WKScriptMessageHandler`),
        /// which then breaks `nonisolated func inboundFrames()`.
        /// `AsyncStream`'s initializer invokes the captured-continuation
        /// closure synchronously, so we can lift `continuation` out of
        /// it during init and assign it after `super.init`.
        /// `AsyncStream<InboundMessage>` is `Sendable`, so a plain
        /// `nonisolated let` suffices — no `(unsafe)`.
        private nonisolated let stream: AsyncStream<InboundMessage>
        /// Retained here because `WKWebView` holds its delegates weakly, and
        /// installed by the window rather than at init so the adapter stays
        /// constructible without an `AppContext` (the driver builds one).
        private nonisolated(unsafe) var webPolicy: WKWebPolicy?

        public init(configuration: WKWebViewConfiguration? = nil) throws {
            var captured: AsyncStream<InboundMessage>.Continuation?
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
            // Inject bridge.js at document start, into the top frame only.
            //
            // It used to go into every frame, which meant a cross-origin
            // `<iframe>` of embedded content — an ad, a map, a widget — reached
            // every command the app registered, with the same arguments the
            // app's own code would use. Nothing legitimate needs that: a
            // *same-origin* frame is the same trust domain and can still call
            // through `window.parent.__SWIFT_PWA__` (the documented pattern,
            // and correctly attributed to the parent), while a cross-origin
            // frame cannot reach the parent's object at all.
            let bridge = try BridgeScript.source()
            let userScript = WKUserScript(
                source: bridge,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
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
            #if os(macOS) && SWIFT_PWA_DRIVER
                if DriverBackground.isRequested { Self.disableWindowOcclusionDetection(on: webView) }
            #endif
            #if os(macOS)
                if #available(macOS 13.3, *) { webView.isInspectable = true }
            #else
                if #available(iOS 16.4, *) { webView.isInspectable = true }
            #endif
        }

        #if os(macOS) && SWIFT_PWA_DRIVER
            /// Stop WebKit throttling this view because its window isn't on
            /// screen — the one thing that makes a backgrounded driven run
            /// possible at all (see ``DriverBackground``).
            ///
            /// Measured on macOS 26.6.2: a window parked off screen or covered
            /// by another serves **0** `requestAnimationFrame` callbacks per
            /// second, and 63 with this off. A page that draws in a rAF
            /// callback therefore does nothing while hidden, and doesn't fail
            /// either — a screenshot comes back as a clean image of stale
            /// content.
            ///
            /// **Timing is the trap.** The flag has to be set while the page is
            /// still being serviced: setting it after a page has already gone
            /// hidden doesn't bring it back (measured — 0 fps, and
            /// `document.visibilityState` stays `hidden`), while setting it any
            /// time before that works, including after the view is already in a
            /// window. Construction is simply the earliest point, and the one
            /// that can't be got wrong.
            ///
            /// **It is private API**, so it's called through `responds(to:)`
            /// and a missing selector degrades to a visible run rather than a
            /// silent one that times out every rAF-dependent test.
            private static func disableWindowOcclusionDetection(on webView: WKWebView) {
                let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
                guard webView.responds(to: selector),
                      let method = class_getInstanceMethod(type(of: webView), selector)
                else {
                    // Fall back to a run with a window on screen: the page
                    // renders, the suite passes, and the person watching can
                    // see why their machine was taken over.
                    DriverBackground.markUnsupported()
                    FileHandle.standardError.writeQuietly(Data("""
                    swift-pwa: this macOS can't switch off WebKit's window occlusion detection, so a \
                    backgrounded run would stop rendering. Showing the window instead — expect it on screen.

                    """.utf8))
                    return
                }
                // A `BOOL` argument can't travel through `perform(_:with:)`,
                // which takes objects; calling the IMP directly is the only
                // spelling that passes a false rather than a pointer.
                typealias SetBool = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
                let implementation = unsafeBitCast(method_getImplementation(method), to: SetBool.self)
                implementation(webView, selector, ObjCBool(false))
            }
        #endif

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

        /// Install the navigation policy and the JavaScript panels — see
        /// ``WKWebPolicy``. Called by each window right after it builds the
        /// adapter, and *before* `load`, so the first navigation is policed
        /// too.
        ///
        /// Without this an off-origin link loads in place and strands the app,
        /// and `alert()` / `confirm()` / `prompt()` do nothing at all.
        @MainActor
        public func attachWebPolicy(policy: ExternalURLPolicy, opener: any URLOpener) {
            let delegate = WKWebPolicy(policy: policy, opener: opener)
            webPolicy = delegate
            webView.navigationDelegate = delegate
            webView.uiDelegate = delegate
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
                    webPolicy?.appOrigin = WebOrigin(url)
                    webView.load(URLRequest(url: url))
                case let .remote(url):
                    // A `.remote` window is its own origin: an app pointed at
                    // a web app navigates around that site freely, and only
                    // leaving *it* counts as leaving the app.
                    webPolicy?.appOrigin = WebOrigin(url)
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

        public nonisolated func inboundMessages() -> AsyncStream<InboundMessage> {
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

        /// Which frame posted `message`, straight from WebKit.
        ///
        /// `WKScriptMessage.frameInfo` is the only trustworthy source for this
        /// — `bridge.js` runs inside the frame in question, so anything it
        /// reports about itself is written by whoever wrote that frame's
        /// content. The same `frameInfo` drives which origin a cross-origin
        /// `confirm()` names, in `WKJavaScriptPanels`.
        ///
        /// `WKFrameInfo`'s properties are `@MainActor` on the Swift 6.1
        /// toolchain CI builds with, and not on newer ones — so reading them
        /// from this `nonisolated` context compiles locally and fails there.
        /// `assumeIsolated` states the invariant instead of depending on the
        /// compiler's opinion of it: WebKit delivers a script message on the
        /// main thread, which is the same guarantee the rest of this class
        /// already runs on.
        private nonisolated static func callerFrame(of message: WKScriptMessage) -> CallerFrame {
            MainActor.assumeIsolated { frameIdentity(of: message) }
        }

        @MainActor
        private static func frameIdentity(of message: WKScriptMessage) -> CallerFrame {
            let info = message.frameInfo
            if info.isMainFrame { return .main }
            let security = info.securityOrigin
            let origin = security.host.isEmpty
                ? nil
                : WebOrigin(
                    scheme: security.protocol,
                    host: security.host,
                    port: security.port == 0 ? nil : Int(security.port)
                )
            return .subframe(origin: origin)
        }

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
                continuation?.yield(InboundMessage(frame: frame, callerFrame: Self.callerFrame(of: message)))
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
