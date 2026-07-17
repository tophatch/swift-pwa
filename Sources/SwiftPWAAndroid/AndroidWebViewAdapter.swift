#if os(Android)
    import CSwiftPWAAndroidJNI
    import Foundation
    import SwiftPWACore

    /// `PWAWebView` implementation backed by `android.webkit.WebView`,
    /// driven through the JNI shim.
    ///
    /// **Threading**: not `@MainActor`. `WebView` API calls (`loadUrl`,
    /// `evaluateJavascript`) must run on the JVM main thread; the
    /// Kotlin-side `SwiftPWABridge` posts to `Handler(Looper.getMainLooper())`
    /// before driving the WebView. Inbound JSON frames arrive on a JNI
    /// binder thread and feed the broadcast continuation directly.
    ///
    /// `bridge.js` is *not* injected via Swift on Android — the
    /// Kotlin host handles document-start injection itself, since
    /// `WebView` exposes no programmatic equivalent of WebKit's
    /// `addUserScript` outside the deprecated `setWebChromeClient`
    /// hooks. Specifically, the Activity calls
    /// `webView.evaluateJavascript(bridgeJs, null)` from
    /// `WebViewClient.onPageStarted`. The Swift side passes the script
    /// source over via the bundler at build time (it's copied into
    /// `assets/swift_pwa/bridge.js`).
    public final class AndroidWebViewAdapter: PWAWebView, @unchecked Sendable {
        // The continuation drives the inbound stream; mutated only at
        // init time, never re-set, so it's safe to read across
        // isolation boundaries.
        private nonisolated(unsafe) var continuation: AsyncStream<InboundFrame>.Continuation?
        private let stream: AsyncStream<InboundFrame>

        public init() {
            var captured: AsyncStream<InboundFrame>.Continuation?
            stream = AsyncStream { captured = $0 }
            continuation = captured
        }

        // MARK: - PWAWebView

        public func load(_ content: WindowContent) {
            AndroidWebViewAdapter.resolveURL(for: content).withCString { c in
                swiftpwa_android_load_url(c)
            }
        }

        /// Map a `WindowContent` to the URL string the Kotlin
        /// `WebViewAssetLoader` understands.
        ///
        /// - `.bundled` resolves to `https://swift-pwa.local/web/<entry>`.
        ///   The Kotlin bridge maps `https://swift-pwa.local/<path>`
        ///   onto `assets/<path>` (same shape as WebView2's
        ///   `SetVirtualHostNameToFolderMapping`); the `web/` URL
        ///   prefix picks up the bundler's `assets/web/` subdir,
        ///   since `AssetsPathHandler`'s public constructor takes
        ///   only `Context` (no base-path argument). The `directory`
        ///   URL is informational on Android — the build-time bundle
        ///   has already copied its contents into the APK.
        /// - `.remote` is passed through unchanged.
        ///
        /// Exposed `internal` so `AndroidAppContext.createWindow` can
        /// use the same resolver when seeding a spawned Activity's
        /// content URL.
        static func resolveURL(for content: WindowContent) -> String {
            switch content {
            case let .bundled(_, entry, _):
                "https://swift-pwa.local/web/\(entry)"
            case let .remote(url):
                url.absoluteString
            }
        }

        public func evaluateJavaScript(_ js: String) async throws -> String? {
            try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<String?, any Error>) in
                let box = EvalBox(continuation: cont)
                let user = Unmanaged.passRetained(box).toOpaque()
                js.withCString { c in
                    swiftpwa_android_evaluate_js(c, evalDoneTrampoline, user)
                }
            }
        }

        public func deliver(_ frame: OutboundFrame) async throws {
            let data = try Envelope.encode(frame)
            guard let json = String(data: data, encoding: .utf8) else {
                throw BridgeError(code: BridgeError.encode, message: "frame is not valid UTF-8")
            }
            // The shim hops to UI thread internally before driving
            // `WebView.evaluateJavascript`. We can call from any
            // thread; no `MainThread.run` needed at this layer.
            json.withCString { c in
                swiftpwa_android_post_to_page(c)
            }
        }

        public func inboundFrames() -> AsyncStream<InboundFrame> { stream }

        public func openDevTools() {
            swiftpwa_android_open_devtools()
        }

        /// Called from the JNI inbound trampoline (via
        /// `AndroidAppContext.routeInbound`) on a binder thread. The
        /// underlying `AsyncStream.Continuation` is documented thread-safe.
        func _ingest(jsonString: String) {
            guard let data = jsonString.data(using: .utf8) else { return }
            do {
                let frame = try Envelope.decode(data)
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

    /// Heap-boxed continuation ferried through `swiftpwa_android_evaluate_js`.
    final class EvalBox: @unchecked Sendable {
        let continuation: CheckedContinuation<String?, any Error>
        init(continuation: CheckedContinuation<String?, any Error>) {
            self.continuation = continuation
        }
    }

    /// `@convention(c)` callback fired by the shim once
    /// `WebView.evaluateJavascript` resolves. Always invoked on the
    /// JVM main thread; we resume the continuation from there.
    let evalDoneTrampoline: @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?
    ) -> Void = { resultPtr, errorPtr, userData in
        guard let userData else { return }
        let box = Unmanaged<EvalBox>.fromOpaque(userData).takeRetainedValue()
        if let errorPtr {
            box.continuation.resume(throwing: BridgeError(
                code: BridgeError.handler,
                message: String(cString: errorPtr)
            ))
            return
        }
        if let resultPtr {
            box.continuation.resume(returning: String(cString: resultPtr))
        } else {
            box.continuation.resume(returning: nil)
        }
    }
#endif
