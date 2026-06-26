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
        /// Applied once the controller is ready (RGBColor is Sendable).
        private let backgroundColor: RGBColor?

        // Mutable pointer fields are `nonisolated(unsafe)` because
        // they're read from `MainThread.run` closures (which Swift
        // 6.1 sees as `@MainActor`-isolated when they capture this
        // class's state). Without the annotation, capturing `self`
        // and reading `self.view` / `self.controller` trips the
        // sending-risk diagnostic. The actual mutation happens only
        // on the UI thread (`_onControllerReady`, `detach`); the
        // unannotated reads are immutable-by-convention.
        private nonisolated(unsafe) var controller: OpaquePointer?
        private nonisolated(unsafe) var view: OpaquePointer?
        private nonisolated(unsafe) var ready = false
        private nonisolated(unsafe) var continuation: AsyncStream<InboundFrame>.Continuation?
        /// Eager `let` rather than a `lazy var` for the same reason
        /// as `WKWebViewAdapter.stream`: Swift 6.1 (CI's Windows
        /// toolchain) refuses `nonisolated` on lazy properties, and
        /// dropping the modifier promotes the property to an
        /// isolation that breaks `nonisolated func inboundFrames()`.
        /// `AsyncStream`'s init invokes the closure synchronously,
        /// so we lift the continuation out and assign it after the
        /// stored property is set. (`AsyncStream` is itself
        /// Sendable, so no `nonisolated(unsafe)` modifier needed.)
        private let stream: AsyncStream<InboundFrame>
        /// The context-level shared router (bundle `/` mount + any
        /// `serveDirectory` mounts). Set in `init`; the bundle root is
        /// installed in `load(_:)`. `WebResourceRequested` interception
        /// resolves served mounts through it.
        private nonisolated(unsafe) var assetProvider: AssetProvider

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
            content _: WindowContent,
            backgroundColor: RGBColor? = nil,
            sharedProvider: AssetProvider
        ) throws {
            self.environment = environment
            self.parent = parent
            self.backgroundColor = backgroundColor
            assetProvider = sharedProvider
            var captured: AsyncStream<InboundFrame>.Continuation?
            stream = AsyncStream { captured = $0 }
            continuation = captured
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

            // Force `IsVisible = TRUE` even though it's the documented
            // default. Cheap and rules out a "controller exists but is
            // hidden" failure mode in case the runtime drops the
            // default in some build.
            swiftpwa_w2_controller_set_visible(ctrl, 1)

            // Native background before first paint (no white flash). ARGB,
            // fully opaque. No-op on runtimes without ICoreWebView2Controller2.
            if let bg = backgroundColor {
                let c = bg.bytes
                swiftpwa_w2_controller_set_background_color(ctrl, 255, c.r, c.g, c.b)
            }

            // Inject bridge.js at document-start. WebView2's API for
            // this is "AddScriptToExecuteOnDocumentCreated" — fires
            // before any page script in every navigation.
            if let view, let bridgeJS = try? BridgeScript.source() {
                bridgeJS.withCString(encodedAs: UTF16.self) { wcs in
                    swiftpwa_w2_view_add_script_on_document_created(view, wcs)
                }
                let user = Unmanaged.passUnretained(self).toOpaque()
                swiftpwa_w2_view_set_web_message_handler(view, messageReceivedTrampoline, user)

                // Intercept requests to the bundle origin so directories
                // added via `ctx.serveDirectory(_:at:)` are served (with
                // range support) from the shared router. Bundle paths fall
                // through to the native virtual-host mapping — the handler
                // only answers requests under a served mount prefix. The
                // filter is broad (`/*`); per-request triage is cheap.
                let resUser = Unmanaged.passUnretained(self).toOpaque()
                "https://swift-pwa.local/*".withCString(encodedAs: UTF16.self) { filterW in
                    swiftpwa_w2_view_intercept_resources(view, filterW, resourceRequestedTrampoline, resUser)
                }
            }

            ready = true
        }

        /// Called from `resourceRequestedTrampoline` on the UI thread for
        /// every request to the bundle origin. Requests that don't fall
        /// under a `serveDirectory` mount are handed back to WebView2's
        /// default handling (the bundle's virtual-host mapping); served
        /// requests are resolved and answered range-aware off disk.
        func _onResourceRequested(uri: String, token: UInt64) {
            guard let view, let url = URL(string: uri) else {
                if let view { swiftpwa_w2_resource_passthrough(view, token) }
                return
            }
            guard assetProvider.isServedPrefix(url) else {
                swiftpwa_w2_resource_passthrough(view, token)
                return
            }
            guard let resolved = assetProvider.resolve(url) else {
                // Under a served prefix but missing / traversal-blocked → 404.
                "text/plain; charset=utf-8".withCString { mime in
                    swiftpwa_w2_resource_respond(view, token, 404, mime, nil, 0)
                }
                return
            }

            // Parse the Range header (if any) the same way every backend does.
            var rangeHeader: String?
            if let raw = swiftpwa_w2_resource_range_header(view, token) {
                rangeHeader = String(cString: raw)
                free(raw)
            }
            let resolution = ByteRange.resolve(header: rangeHeader, fileSize: resolved.fileSize)

            let path = resolved.fileURL.withUnsafeFileSystemRepresentation { rep -> String in
                rep.map { String(cString: $0) } ?? resolved.fileURL.path
            }
            let total = resolved.fileSize
            path.withCString(encodedAs: UTF16.self) { pathW in
                resolved.mimeType.withCString { mime in
                    switch resolution {
                    case .full:
                        swiftpwa_w2_resource_respond_file(view, token, 200, mime, pathW, 0, total, total)
                    case let .partial(offset, length):
                        swiftpwa_w2_resource_respond_file(view, token, 206, mime, pathW, offset, length, total)
                    case .unsatisfiable:
                        swiftpwa_w2_resource_respond_file(view, token, 416, mime, pathW, 0, 0, total)
                    }
                }
            }
        }

        /// Pop the WebView2 DevTools window. Useful as a proof-of-life
        /// signal: if DevTools comes up but the main window is blank,
        /// the runtime is fine and the issue is in window painting /
        /// composition. If DevTools doesn't come up either, the
        /// controller is wedged.
        public func openDevTools() {
            guard let view else { return }
            swiftpwa_w2_view_open_devtools(view)
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
            // Called synchronously from `Win32Window.init`, which is
            // already on the UI thread (main actor + main OS thread),
            // so we just invoke WebView2 directly — no Task / MainThread
            // hop. (`evaluateJavaScript` and `deliver` *do* hop because
            // they're called from `BridgeRuntime`'s cooperative-pool
            // pump.)
            guard let view else { return }
            switch content {
            case let .bundled(directory, entry):
                // Use the platform's native path representation —
                // `URL.path` on Windows can return a POSIX-shaped
                // string with forward slashes, which
                // `SetVirtualHostNameToFolderMapping` silently
                // ignores. `withUnsafeFileSystemRepresentation`
                // gives us the host-native form.
                let folderPath = directory.withUnsafeFileSystemRepresentation { rep -> String in
                    rep.map { String(cString: $0) } ?? directory.path
                }
                let host = "swift-pwa.local"
                let urlString = "https://\(host)/\(entry)"
                folderPath.withCString(encodedAs: UTF16.self) { folder in
                    host.withCString(encodedAs: UTF16.self) { hostW in
                        swiftpwa_w2_view_map_virtual_host(view, hostW, folder, 2)
                    }
                }
                urlString.withCString(encodedAs: UTF16.self) { urlW in
                    swiftpwa_w2_view_navigate(view, urlW)
                }
                // Bundle is served natively by the virtual-host mapping
                // above; the shared router still records the `/` root so
                // `serveDirectory` mounts (handled via interception below)
                // can resolve relative file paths consistently.
                assetProvider.setBundleRoot(directory)
            case let .remote(url):
                url.absoluteString.withCString(encodedAs: UTF16.self) { urlW in
                    swiftpwa_w2_view_navigate(view, urlW)
                }
            }
        }

        public func evaluateJavaScript(_ js: String) async throws -> String? {
            // We use `MainThread.run` (the dispatcher-window hook)
            // rather than `Task { @MainActor in }` because Swift's
            // MainActor executor isn't drained by our `GetMessageW`
            // pump on Windows.
            //
            // No local binding for `view` — reading `self.view`
            // directly inside the closure works because the property
            // is `nonisolated(unsafe)`. Carrying the `EvalBox` as a
            // class ref (Sendable) and only converting to an opaque
            // pointer inside the closure keeps Swift 6.1 happy —
            // raw pointers don't cross isolation boundaries.
            let snippet = js
            return try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<String?, any Error>) in
                let evalBox = EvalBox(continuation: cont)
                Task { [self] in
                    await MainThread.run {
                        guard let v = self.view else {
                            evalBox.continuation.resume(returning: nil)
                            return
                        }
                        let boxPtr = Unmanaged.passRetained(evalBox).toOpaque()
                        snippet.withCString(encodedAs: UTF16.self) { wcs in
                            swiftpwa_w2_view_execute_script(
                                v, wcs, evalCompleteTrampoline, boxPtr
                            )
                        }
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
            // `MainThread.run` (dispatcher window) instead of
            // `MainActor.run`: see `load(...)` for why a MainActor
            // hop on Windows under our `GetMessageW` pump never
            // fires. `self.view` is `nonisolated(unsafe)`, so we
            // read it inside the closure rather than binding a
            // local — Swift 6.1 flags `nonisolated(unsafe) let`
            // crossings into a `@MainActor` closure.
            await MainThread.run { [self] in
                guard let v = view else { return }
                json.withCString(encodedAs: UTF16.self) { wcs in
                    swiftpwa_w2_view_post_web_message_string(v, wcs)
                }
            }
        }

        public func inboundFrames() -> AsyncStream<InboundFrame> {
            stream
        }

        /// Called from `messageReceivedTrampoline` whenever the page
        /// posts a string via `window.chrome.webview.postMessage(json)`.
        /// Always invoked on the UI thread; the continuation it writes
        /// to is intrinsically thread-safe.
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

    /// `@convention(c)` callback from `swiftpwa_w2_view_intercept_resources`.
    /// Fires on the UI thread for each request matching the filter.
    let resourceRequestedTrampoline: @convention(c) (
        UnsafePointer<CChar>?, UInt64, UnsafeMutableRawPointer?
    ) -> Void = { uriPtr, token, userData in
        guard let uriPtr, let userData else { return }
        let uri = String(cString: uriPtr)
        let adapter = Unmanaged<WebView2Adapter>.fromOpaque(userData).takeUnretainedValue()
        adapter._onResourceRequested(uri: uri, token: token)
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
