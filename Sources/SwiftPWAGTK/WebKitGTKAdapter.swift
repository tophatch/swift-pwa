#if os(Linux)
    import CGtk3Shim
    import CWebKitGTK4Shim
    import Foundation
    import SwiftPWACore

    /// `WebView` implementation backed by WebKitGTK 4.1.
    ///
    /// `webkit_web_view_new_*` returns `GtkWidget*` (the WebView is a
    /// GtkWidget by GObject inheritance). We store the widget pointer
    /// once and rebind to `WebKitWebView*` at each WebKit call site.
    @MainActor
    public final class WebKitGTKAdapter: PWAWebView {
        /// Owned `GtkWidget*` whose concrete type is `WebKitWebView`.
        private let viewWidget: UnsafeMutablePointer<GtkWidget>
        private let userContent: UnsafeMutablePointer<WebKitUserContentManager>
        private var continuation: AsyncStream<InboundFrame>.Continuation?
        private lazy var stream: AsyncStream<InboundFrame> = AsyncStream { c in self.continuation = c }
        private var assetProvider: AssetProvider?

        private var webView: UnsafeMutablePointer<WebKitWebView> {
            UnsafeMutableRawPointer(viewWidget).assumingMemoryBound(to: WebKitWebView.self)
        }

        init(parent: UnsafeMutablePointer<GtkWidget>, content: WindowContent) throws {
            // Create the user content manager and inject bridge.js as a user script.
            guard let ucm = webkit_user_content_manager_new() else {
                throw BridgeError(code: BridgeError.handler, message: "webkit_user_content_manager_new failed")
            }
            userContent = ucm
            let bridgeSource = try BridgeScript.source()
            bridgeSource.withCString { src in
                if let script = webkit_user_script_new(
                    src,
                    WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES,
                    WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
                    nil,
                    nil
                ) {
                    webkit_user_content_manager_add_script(ucm, script)
                    webkit_user_script_unref(script)
                }
            }
            // Register the message handler.
            BridgeScript.messageHandlerName.withCString { name in
                _ = webkit_user_content_manager_register_script_message_handler(ucm, name)
            }

            // Create the web view.
            guard let view = webkit_web_view_new_with_user_content_manager(ucm) else {
                throw BridgeError(code: BridgeError.handler, message: "webkit_web_view_new failed")
            }
            viewWidget = view

            // Place the web view inside the parent container.
            let container = UnsafeMutableRawPointer(parent).assumingMemoryBound(to: GtkContainer.self)
            gtk_container_add(container, view)

            // Wire scheme handler if bundled content was specified.
            if case let .bundled(directory, _) = content {
                let provider = AssetProvider(root: directory)
                assetProvider = provider
                registerScheme(provider: provider)
            }

            // Connect `script-message-received::__SwiftPWA__post` so JS
            // calls to `mh.postMessage(json)` make it back into Swift.
            connectMessageHandler(ucm: ucm)
        }

        private func connectMessageHandler(ucm: UnsafeMutablePointer<WebKitUserContentManager>) {
            // Heap-box self so the C callback can find us via user_data.
            // Released by `messageBoxDestroy` when the signal is disconnected.
            let box = Unmanaged.passRetained(MessageBox(self)).toOpaque()
            let signal = "script-message-received::\(BridgeScript.messageHandlerName)"
            signal.withCString { name in
                _ = g_signal_connect_data(
                    UnsafeMutableRawPointer(ucm),
                    name,
                    unsafeBitCast(messageReceivedTrampoline, to: GCallback.self),
                    box,
                    messageBoxDestroy,
                    GConnectFlags(rawValue: 0)
                )
            }
        }

        private func registerScheme(provider: AssetProvider) {
            guard let context = webkit_web_view_get_context(webView) else { return }
            let payload = Unmanaged.passRetained(SchemeBox(provider: provider)).toOpaque()
            provider.scheme.withCString { scheme in
                webkit_web_context_register_uri_scheme(
                    context,
                    scheme,
                    { request, userData in
                        guard let request, let userData else { return }
                        let box = Unmanaged<SchemeBox>.fromOpaque(userData).takeUnretainedValue()
                        box.handle(request: request)
                    },
                    payload,
                    nil
                )
            }
        }

        // MARK: - PWAWebView

        public func load(_ content: WindowContent) {
            switch content {
            case let .bundled(_, entry):
                let url = "pwa://localhost/\(entry)"
                url.withCString { webkit_web_view_load_uri(webView, $0) }
            case let .remote(url):
                url.absoluteString.withCString { webkit_web_view_load_uri(webView, $0) }
            }
        }

        public func evaluateJavaScript(_ js: String) async throws -> String? {
            // Fire-and-forget for v0.1; full async-result threading via
            // GAsyncResult is left for a follow-up.
            js.withCString {
                webkit_web_view_evaluate_javascript(
                    webView, $0, gssize(-1), nil, nil, nil, nil, nil
                )
            }
            return nil
        }

        public func deliver(_ frame: OutboundFrame) async throws {
            let data = try Envelope.encode(frame)
            guard let json = String(data: data, encoding: .utf8) else {
                throw BridgeError(code: BridgeError.encode, message: "frame is not valid UTF-8")
            }
            let escaped = try jsString(json)
            let snippet = "globalThis.__SWIFT_PWA__?.__deliver(\(escaped));"
            _ = try await evaluateJavaScript(snippet)
        }

        public func inboundFrames() -> AsyncStream<InboundFrame> {
            _ = stream
            return stream
        }

        /// Called by the C-side signal handler trampoline whenever JS
        /// posts a frame via `mh.postMessage(...)`.
        public func _ingest(jsonString: String) {
            guard let data = jsonString.data(using: .utf8) else { return }
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

        deinit { continuation?.finish() }
    }

    /// Heap box holding a back-reference to the adapter for the GObject
    /// signal callback. Released by `messageBoxDestroy` when the signal
    /// is disconnected (which happens automatically when the
    /// WebKitUserContentManager is finalized).
    private final class MessageBox {
        weak var adapter: WebKitGTKAdapter?
        init(_ adapter: WebKitGTKAdapter) { self.adapter = adapter }
    }

    /// `@convention(c)` trampoline matching the GObject callback shape
    /// for `WebKitUserContentManager::script-message-received` in
    /// WebKitGTK 2.40+ (4.1 ABI):
    /// `void (*)(WebKitUserContentManager*, JSCValue*, gpointer)`.
    ///
    /// (The older API took a `WebKitJavascriptResult*`, which was
    /// removed in 2.40 in favour of passing `JSCValue*` directly.)
    ///
    /// Bridge.js always sends string payloads (it `JSON.stringify`s
    /// the envelope before posting), so we extract the value as UTF-8,
    /// free the C buffer, and dispatch to the Swift adapter on the
    /// main actor.
    private let messageReceivedTrampoline: @convention(c) (
        UnsafeMutablePointer<WebKitUserContentManager>?,
        UnsafeMutablePointer<JSCValue>?,
        gpointer?
    ) -> Void = { _, value, userData in
        guard let value, let userData else { return }
        guard let cstr = jsc_value_to_string(value) else { return }
        let json = String(cString: cstr)
        g_free(cstr)
        // Pull the (Sendable, MainActor-isolated) adapter reference
        // out of the box before crossing into the MainActor closure.
        // Capturing the box itself trips strict-concurrency because
        // `MessageBox` is not Sendable.
        let adapter = Unmanaged<MessageBox>.fromOpaque(userData).takeUnretainedValue().adapter
        // Signals fire on the GTK main thread, which is also Swift's
        // main thread; jump to MainActor isolation without an async hop.
        MainActor.assumeIsolated { adapter?._ingest(jsonString: json) }
    }

    /// `@convention(c)` GClosureNotify that releases the heap-boxed
    /// `MessageBox` when the signal is disconnected (e.g. when the
    /// user content manager finalizes).
    private let messageBoxDestroy: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = {
        userData, _ in
        guard let userData else { return }
        Unmanaged<MessageBox>.fromOpaque(userData).release()
    }

    /// Heap box holding the scheme handler context across the C boundary.
    private final class SchemeBox {
        let provider: AssetProvider
        init(provider: AssetProvider) { self.provider = provider }

        func handle(request: UnsafeMutablePointer<WebKitURISchemeRequest>) {
            guard let urlCStr = webkit_uri_scheme_request_get_uri(request) else {
                webkit_uri_scheme_request_finish_error(request, nil)
                return
            }
            let urlString = String(cString: urlCStr)
            guard let url = URL(string: urlString),
                  let resolved = provider.resolve(url),
                  let data = try? Data(contentsOf: resolved.fileURL)
            else {
                webkit_uri_scheme_request_finish_error(request, nil)
                return
            }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                let stream = g_memory_input_stream_new_from_data(base, gssize(data.count), nil)
                resolved.mimeType.withCString { mime in
                    webkit_uri_scheme_request_finish(
                        request,
                        stream,
                        gint64(data.count),
                        mime
                    )
                }
                g_object_unref(UnsafeMutableRawPointer(stream))
            }
        }
    }

    private func jsString(_ s: String) throws -> String {
        let data = try JSONEncoder().encode(s)
        guard let out = String(data: data, encoding: .utf8) else {
            throw BridgeError(code: BridgeError.encode, message: "failed to encode JS string")
        }
        return out
    }
#endif
