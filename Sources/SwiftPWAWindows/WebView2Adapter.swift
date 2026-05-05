#if os(Windows)
    import CWebView2Shim
    import Foundation
    import SwiftPWACore
    import WinSDK

    /// `PWAWebView` implementation backed by Microsoft Edge WebView2.
    ///
    /// **Threading**: not `@MainActor`. WebView2 calls are routed
    /// through `MainThread.run`, so the same code paths work whether
    /// the caller is on the main actor or a cooperative-pool task.
    /// All COM callbacks fire on the UI thread (the thread that
    /// kicked off env / controller creation), and the C shim guards
    /// its own state with a per-process mutex.
    public final class WebView2Adapter: PWAWebView, @unchecked Sendable {
        private let environment: OpaquePointer
        private let parent: HWND

        private var controller: OpaquePointer?
        private var view: OpaquePointer?
        private var ready = false
        private var continuation: AsyncStream<InboundFrame>.Continuation?
        private lazy var stream: AsyncStream<InboundFrame> = AsyncStream { c in self.continuation = c }
        private var assetProvider: AssetProvider?

        // The shim hands out `swiftpwa_w2_view *` per-call. We cache
        // the most recently issued one so `respond` can find its way
        // back to the owner; freeing happens with the controller.
        // (The shim allocates these out of `new`; we `free` by simply
        // deallocating the controller, which doesn't reach back into
        // the view tags. Since they're just thin tagged structs with
        // no destructors of their own, leaking them on detach is fine
        // for v0.2 — at most one per window. v0.3 should add an
        // explicit `swiftpwa_w2_view_release` if it ever becomes a
        // measurable footprint.)

        public init(
            environment: OpaquePointer,
            parent: HWND,
            content _: WindowContent
        ) throws {
            self.environment = environment
            self.parent = parent
            // Async controller creation kicks off here; the caller
            // will pump messages via `pumpUntilReady` until the
            // callback flips `ready`.
            let user = Unmanaged.passRetained(self).toOpaque()
            swiftpwa_w2_create_controller(
                environment,
                UnsafeMutableRawPointer(parent),
                controllerReadyTrampoline,
                user
            )
        }

        /// Drive the local message pump until the WebView2 controller
        /// is up. `Win32Window.init` calls this synchronously so the
        /// rest of its setup (load, fitTo) happens against a real view.
        func pumpUntilReady() {
            var msg = MSG()
            while !ready {
                if !GetMessageW(&msg, nil, 0, 0) { break }
                TranslateMessage(&msg)
                DispatchMessageW(&msg)
            }
        }

        /// Called from `controllerReadyTrampoline` once WebView2 hands
        /// us a controller + view. Wires up the bridge user-script,
        /// the web-message handler, and the `pwa://` resource hook.
        func _onControllerReady(_ ctrl: OpaquePointer?) {
            guard let ctrl else {
                ready = true
                return
            }
            controller = ctrl
            view = swiftpwa_w2_controller_view(ctrl)

            // Inject bridge.js at document-start. WebView2's API for
            // this is "AddScriptToExecuteOnDocumentCreated" — fires
            // before any page script in every navigation.
            if let view, let bridgeJS = try? BridgeScript.source() {
                bridgeJS.withCString(encodedAs: UTF16.self) { wcs in
                    swiftpwa_w2_view_add_script_on_document_created(view, wcs)
                }
                let user = Unmanaged.passUnretained(self).toOpaque()
                swiftpwa_w2_view_set_web_message_handler(view, messageReceivedTrampoline, user)
            }

            ready = true
        }

        /// Resize the WebView2 host to fill `client` (in pixel coords
        /// inside the parent HWND). Called from `WM_SIZE` and once
        /// during init so the view is positioned the moment it's
        /// shown.
        func fitTo(client: RECT) {
            guard let controller else { return }
            swiftpwa_w2_controller_set_bounds(
                controller,
                client.left, client.top, client.right, client.bottom
            )
        }

        /// Tear down the controller. Called from `Win32Window` on
        /// `WM_DESTROY`; releases COM refs and stops the WebView2
        /// process for this window.
        func detach() {
            if let controller {
                swiftpwa_w2_controller_close(controller)
                swiftpwa_w2_controller_release(controller)
                self.controller = nil
                view = nil
            }
            continuation?.finish()
        }

        // MARK: - PWAWebView

        public func load(_ content: WindowContent) {
            // WebView2 needs a real http(s) origin for fetch / module
            // loading — `file://` is heavily restricted, and a
            // `pwa://` custom scheme doesn't get same-origin
            // semantics out of the box. So for bundled content we
            // map a virtual host (`SetVirtualHostNameToFolderMapping`)
            // and navigate there. For remote content we navigate
            // directly.
            //
            // `Task { @MainActor in … }` rather than the
            // `Task { … await MainThread.run { … } }` form: Swift
            // 6.3's strict-concurrency check refuses to send the
            // captured `OpaquePointer` view handle through the
            // MainThread.run closure boundary, even though
            // OpaquePointer is conceptually Sendable. Hopping
            // straight to MainActor avoids the inner closure
            // crossing. (Same approach as `WKWebViewAdapter`.)
            let viewLocal = view
            switch content {
            case let .bundled(directory, entry):
                let host = "swift-pwa.local"
                let urlString = "https://\(host)/\(entry)"
                Task { @MainActor in
                    guard let viewLocal else { return }
                    directory.path.withCString(encodedAs: UTF16.self) { folder in
                        host.withCString(encodedAs: UTF16.self) { hostW in
                            swiftpwa_w2_view_map_virtual_host(viewLocal, hostW, folder, 2)
                        }
                    }
                    urlString.withCString(encodedAs: UTF16.self) { urlW in
                        swiftpwa_w2_view_navigate(viewLocal, urlW)
                    }
                }
                assetProvider = AssetProvider(root: directory)
            case let .remote(url):
                Task { @MainActor in
                    guard let viewLocal else { return }
                    url.absoluteString.withCString(encodedAs: UTF16.self) { urlW in
                        swiftpwa_w2_view_navigate(viewLocal, urlW)
                    }
                }
            }
        }

        public func evaluateJavaScript(_ js: String) async throws -> String? {
            let viewLocal = view
            let snippet = js
            return try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<String?, any Error>) in
                let box = Unmanaged.passRetained(EvalBox(continuation: cont)).toOpaque()
                // `nonisolated(unsafe)` on a local because the
                // `MainActor.assumeIsolated` closure below otherwise
                // captures a non-Sendable raw pointer. The box's
                // memory is released exactly once via the same path
                // (`takeRetainedValue` on either branch).
                nonisolated(unsafe) let boxPtr = box
                Task { @MainActor in
                    guard let viewLocal else {
                        Unmanaged<EvalBox>.fromOpaque(boxPtr).takeRetainedValue()
                            .continuation.resume(returning: nil)
                        return
                    }
                    snippet.withCString(encodedAs: UTF16.self) { wcs in
                        swiftpwa_w2_view_execute_script(
                            viewLocal, wcs, evalCompleteTrampoline, boxPtr
                        )
                    }
                }
            }
        }

        public func deliver(_ frame: OutboundFrame) async throws {
            // Two ways to send a string into the page from the host:
            // (a) `PostWebMessageAsString`, which surfaces as a
            //     `message` event on `window.chrome.webview`;
            // (b) `ExecuteScript("globalThis.__SWIFT_PWA__.__deliver(...)")`.
            //
            // We use (a) because it avoids re-parsing on the JS side
            // (postMessage delivers the string verbatim, no JSON-in-JS
            // double-encode), and bridge.js subscribes to it.
            let data = try Envelope.encode(frame)
            guard let json = String(data: data, encoding: .utf8) else {
                throw BridgeError(code: BridgeError.encode, message: "frame is not valid UTF-8")
            }
            let viewLocal = view
            await MainActor.run {
                guard let viewLocal else { return }
                json.withCString(encodedAs: UTF16.self) { wcs in
                    swiftpwa_w2_view_post_web_message_string(viewLocal, wcs)
                }
            }
        }

        public func inboundFrames() -> AsyncStream<InboundFrame> {
            _ = stream
            return stream
        }

        /// Called from `messageReceivedTrampoline` whenever the page
        /// posts a string via `window.chrome.webview.postMessage(json)`.
        /// Always invoked on the UI thread; the continuation it writes
        /// to is intrinsically thread-safe.
        func _ingest(jsonString: String) {
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

        deinit {
            // `detach()` is the right place to release the controller
            // and is called by `Win32Window` on close. If we get here
            // without a detach (e.g. an error during init), best-effort
            // close anyway so we don't leave a WebView2 process behind.
            if let controller {
                swiftpwa_w2_controller_release(controller)
            }
            continuation?.finish()
        }
    }

    /// Heap-boxed continuation ferried through `swiftpwa_w2_view_execute_script`.
    /// Marked `@unchecked Sendable` because the continuation is itself
    /// sendable and the box is owned by exactly one party at a time.
    final class EvalBox: @unchecked Sendable {
        let continuation: CheckedContinuation<String?, any Error>
        init(continuation: CheckedContinuation<String?, any Error>) {
            self.continuation = continuation
        }
    }

    // MARK: - C trampolines

    /// `@convention(c)` callback from `swiftpwa_w2_create_controller`.
    /// Always fires on the UI thread.
    let controllerReadyTrampoline: @convention(c) (
        OpaquePointer?, Int32, UnsafeMutableRawPointer?
    ) -> Void = { ctrlPtr, hr, userData in
        guard let userData else { return }
        // `passRetained` in init; balance with `takeRetainedValue` here.
        let adapter = Unmanaged<WebView2Adapter>.fromOpaque(userData).takeRetainedValue()
        if hr != 0 {
            FileHandle.standardError.write(Data(
                "swift-pwa: CreateCoreWebView2Controller failed: 0x\(String(UInt32(bitPattern: hr), radix: 16))\n".utf8
            ))
        }
        // We're already on the UI thread (the controller-ready
        // callback always fires on the call thread). Avoid the
        // MainThread hop and dispatch directly.
        //
        // `nonisolated(unsafe)` on the local because Swift 6.3's
        // strict-concurrency check otherwise refuses to capture the
        // `OpaquePointer?` controller handle into the
        // `MainActor.assumeIsolated` closure.
        nonisolated(unsafe) let ctrl = ctrlPtr
        MainActor.assumeIsolated {
            adapter._onControllerReady(ctrl)
        }
    }

    /// `@convention(c)` callback from `swiftpwa_w2_view_set_web_message_handler`.
    let messageReceivedTrampoline: @convention(c) (
        UnsafePointer<CChar>?, UnsafeMutableRawPointer?
    ) -> Void = { jsonPtr, userData in
        guard let jsonPtr, let userData else { return }
        let json = String(cString: jsonPtr)
        let adapter = Unmanaged<WebView2Adapter>.fromOpaque(userData).takeUnretainedValue()
        adapter._ingest(jsonString: json)
    }

    /// `@convention(c)` callback from `swiftpwa_w2_view_execute_script`.
    let evalCompleteTrampoline: @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?
    ) -> Void = { jsonPtr, errorPtr, userData in
        guard let userData else { return }
        let box = Unmanaged<EvalBox>.fromOpaque(userData).takeRetainedValue()
        if let errorPtr {
            box.continuation.resume(throwing: BridgeError(
                code: BridgeError.handler,
                message: String(cString: errorPtr)
            ))
            return
        }
        if let jsonPtr {
            box.continuation.resume(returning: String(cString: jsonPtr))
        } else {
            box.continuation.resume(returning: nil)
        }
    }
#endif
