#if os(Linux)
    import CGtk3Shim
    import CWebKitGTK4Shim
    import Foundation
    import SwiftPWACore

    /// `WebView` implementation backed by WebKitGTK 4.1.
    ///
    /// **Threading**: not `@MainActor`. WebKit calls (`webkit_web_view_*`)
    /// are routed through `MainThread.run` so they execute on GTK's
    /// main thread regardless of which executor the calling Task is on.
    /// `_ingest(jsonString:)` is invoked from the C signal handler
    /// trampoline (which fires on the main thread); the continuation
    /// it writes to is intrinsically thread-safe. `evaluateJavaScript`
    /// schedules the async-ready callback on the same GMainContext, so
    /// resuming the caller's Swift continuation also happens on the
    /// main thread.
    public final class WebKitGTKAdapter: PWAWebView, @unchecked Sendable {
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

            // Enable the WebKit inspector. Without this,
            // `webkit_web_inspector_show` is a no-op — the inspector
            // object exists but the developer-extras flag gates the
            // window from actually appearing.
            let webViewPtr = UnsafeMutableRawPointer(view)
                .assumingMemoryBound(to: WebKitWebView.self)
            if let settings = webkit_web_view_get_settings(webViewPtr) {
                webkit_settings_set_enable_developer_extras(settings, gboolean(1))
            }

            // Connect `script-message-received` so JS calls to
            // `mh.postMessage(json)` make it back into Swift.
            connectMessageHandler(ucm: ucm)
        }

        private func connectMessageHandler(ucm: UnsafeMutablePointer<WebKitUserContentManager>) {
            // Heap-box self so the C callback can find us via user_data.
            // Released by `messageBoxDestroy` when the signal is disconnected.
            let box = Unmanaged.passRetained(MessageBox(self)).toOpaque()
            // Connect to the bare signal (no `::detail`). We register
            // exactly one script-message handler per content manager,
            // so detail filtering would only add noise.
            "script-message-received".withCString { name in
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
            // Called from anywhere; webkit_web_view_load_uri must run
            // on the GTK main thread. Pass the widget pointer through
            // a `UInt` so strict concurrency lets us cross actors.
            let raw = UInt(bitPattern: viewWidget)
            Task {
                await MainThread.run {
                    guard let view = UnsafeMutablePointer<GtkWidget>(bitPattern: raw) else { return }
                    let webView = UnsafeMutableRawPointer(view)
                        .assumingMemoryBound(to: WebKitWebView.self)
                    switch content {
                    case let .bundled(_, entry):
                        let url = "pwa://localhost/\(entry)"
                        url.withCString { webkit_web_view_load_uri(webView, $0) }
                    case let .remote(url):
                        url.absoluteString.withCString { webkit_web_view_load_uri(webView, $0) }
                    }
                }
            }
        }

        public func evaluateJavaScript(_ js: String) async throws -> String? {
            // The C wrapper schedules `evaluateJavaScriptCallback` once
            // the page returns. We heap-box the continuation, retain it
            // across the C boundary, and resume it from the trampoline.
            // `swiftpwa_evaluate_javascript` must be invoked on the GTK
            // main thread; the GAsyncReadyCallback fires there too, so
            // the continuation resume happens on the main thread.
            //
            // Pointers are laundered through `UInt` because raw pointers
            // aren't `Sendable` under Swift 6 strict concurrency.
            let viewRaw = UInt(bitPattern: viewWidget)
            return try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<String?, any Error>) in
                let boxRaw = UInt(bitPattern: Unmanaged.passRetained(
                    EvalBox(continuation: cont)
                ).toOpaque())
                let snippet = js
                Task {
                    await MainThread.run {
                        guard let boxPtr = UnsafeMutableRawPointer(bitPattern: boxRaw) else {
                            return
                        }
                        guard let view = UnsafeMutablePointer<GtkWidget>(bitPattern: viewRaw) else {
                            // View deallocated before we got here — release
                            // the box and resume with nil.
                            Unmanaged<EvalBox>.fromOpaque(boxPtr).takeRetainedValue()
                                .continuation.resume(returning: nil)
                            return
                        }
                        let webView = UnsafeMutableRawPointer(view)
                            .assumingMemoryBound(to: WebKitWebView.self)
                        snippet.withCString { cstr in
                            swiftpwa_evaluate_javascript(
                                webView, cstr, evaluateJavaScriptCallback, boxPtr
                            )
                        }
                    }
                }
            }
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

        public func openDevTools() {
            // `webkit_web_view_get_inspector` is in the WebKitGTK 4.1
            // umbrella header pulled in by the C shim; calls must run
            // on the GTK main thread, same as everything else.
            let raw = UInt(bitPattern: viewWidget)
            Task {
                await MainThread.run {
                    guard let view = UnsafeMutablePointer<GtkWidget>(bitPattern: raw) else { return }
                    let webView = UnsafeMutableRawPointer(view)
                        .assumingMemoryBound(to: WebKitWebView.self)
                    if let inspector = webkit_web_view_get_inspector(webView) {
                        webkit_web_inspector_show(inspector)
                    }
                }
            }
        }

        /// Called by the C-side signal handler trampoline whenever JS
        /// posts a frame via `mh.postMessage(...)`. Always invoked on
        /// the GTK main thread, but the continuation is thread-safe so
        /// it doesn't matter.
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
    /// is disconnected.
    final class MessageBox {
        weak var adapter: WebKitGTKAdapter?
        init(_ adapter: WebKitGTKAdapter) { self.adapter = adapter }
    }

    /// Heap box carrying a `CheckedContinuation` across the C boundary
    /// for `swiftpwa_evaluate_javascript`. Marked `@unchecked Sendable`
    /// because the continuation is itself sendable and the box is
    /// owned by exactly one party at a time (Swift hands it to C, C
    /// hands it back via `evaluateJavaScriptCallback`).
    final class EvalBox: @unchecked Sendable {
        let continuation: CheckedContinuation<String?, any Error>
        init(continuation: CheckedContinuation<String?, any Error>) {
            self.continuation = continuation
        }
    }

    /// `@convention(c)` callback for `swiftpwa_evaluate_javascript`.
    /// Fires on the GTK main thread once the JS engine returns.
    let evaluateJavaScriptCallback: @convention(c) (
        UnsafeMutablePointer<CChar>?,
        UnsafeMutablePointer<CChar>?,
        UnsafeMutableRawPointer?
    ) -> Void = { jsonPtr, errorPtr, userData in
        guard let userData else { return }
        let box = Unmanaged<EvalBox>.fromOpaque(userData).takeRetainedValue()
        if let errorPtr {
            let msg = String(cString: errorPtr)
            g_free(UnsafeMutableRawPointer(errorPtr))
            box.continuation.resume(throwing: BridgeError(
                code: BridgeError.handler, message: msg
            ))
            return
        }
        if let jsonPtr {
            let json = String(cString: jsonPtr)
            g_free(UnsafeMutableRawPointer(jsonPtr))
            box.continuation.resume(returning: json)
        } else {
            box.continuation.resume(returning: nil)
        }
    }

    /// `@convention(c)` trampoline for `script-message-received`.
    /// (See `swiftpwa_extract_message_string` in the C shim for why
    /// the value arg is typed as `gpointer` — it's a boxed type, not
    /// a GTypeInstance.)
    let messageReceivedTrampoline: @convention(c) (
        UnsafeMutablePointer<WebKitUserContentManager>?,
        gpointer?,
        gpointer?
    ) -> Void = { _, valueArg, userData in
        guard let valueArg, let userData else { return }
        guard let cstr = swiftpwa_extract_message_string(valueArg) else { return }
        let json = String(cString: cstr)
        g_free(cstr)
        let adapter = Unmanaged<MessageBox>.fromOpaque(userData).takeUnretainedValue().adapter
        // We're already on the GTK main thread (signals fire there);
        // call directly without a hop.
        adapter?._ingest(jsonString: json)
    }

    /// `@convention(c)` GClosureNotify that releases the heap-boxed
    /// `MessageBox` when the signal is disconnected.
    let messageBoxDestroy: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = {
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
