#if canImport(WebKit) && (os(macOS) || os(iOS))
    import _SwiftPWATestSupport
    import Foundation
    @testable import SwiftPWACore
    @testable import SwiftPWAWebKit
    import Testing
    import WebKit

    @Suite("WKWebView ↔ Swift round-trip")
    @MainActor
    struct WKBridgeIntegrationTests {
        /// Spins up a real WKWebView, registers an `echo` command, loads
        /// an HTML fixture that calls `__SWIFT_PWA__.invoke('echo', ...)`,
        /// and verifies the reply arrives back in JS.
        @Test("invoke echo round-trips through a real WKWebView")
        func echoRoundTrip() async throws {
            let app = MockAppContext()
            app.registry.register("echo", typed: { (args: EchoArgs, _) -> EchoArgs in args })

            let adapter = try WKWebViewAdapter(configuration: WKWebViewConfiguration())
            let win = MockWindow(webView: adapter)
            app.attach(win)

            let bridge = BridgeRuntime(
                webView: adapter,
                registry: app.registry,
                windowID: win.id,
                app: app
            )
            bridge.start()
            defer { bridge.stop() }

            let html = """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
            <script>
              window.__result = null;
              (async () => {
                try {
                  window.__result = JSON.stringify(
                    await __SWIFT_PWA__.invoke('echo', { value: 'hello world' })
                  );
                } catch (e) {
                  window.__result = 'ERR: ' + e.message;
                }
              })();
            </script></body></html>
            """
            adapter.webView.loadHTMLString(html, baseURL: nil)

            // Poll the JS side for the result with a generous timeout.
            let result = try await waitForJSResult(in: adapter)
            #expect(result == #"{"value":"hello world"}"#)
        }

        /// Drives the real `__SWIFT_PWA__.session(...)` sugar (bridge.js) through
        /// a real WKWebView against a `registerSession` handler: open a session,
        /// push two client frames into it, collect the echoed downstream events,
        /// then close. This is the duplex path (#5) verified end-to-end on macOS.
        @Test("session push/receive round-trips through a real WKWebView")
        func sessionRoundTrip() async throws {
            let app = MockAppContext()
            app.registry.registerSession(
                "test.echo",
                typed: { (open: SessionOpen, inbound: BridgeInbound<SessionFrame>, _)
                    -> AsyncThrowingStream<SessionEvent, any Error> in
                    AsyncThrowingStream { continuation in
                        let task = Task {
                            for await frame in inbound {
                                continuation.yield(SessionEvent(echo: open.prefix + frame.text))
                            }
                            continuation.finish()
                        }
                        continuation.onTermination = { _ in task.cancel() }
                    }
                }
            )

            let adapter = try WKWebViewAdapter(configuration: WKWebViewConfiguration())
            let win = MockWindow(webView: adapter)
            app.attach(win)

            let bridge = BridgeRuntime(
                webView: adapter,
                registry: app.registry,
                windowID: win.id,
                app: app
            )
            bridge.start()
            defer { bridge.stop() }

            let html = """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
            <script>
              window.__result = null;
              const got = [];
              const sess = __SWIFT_PWA__.session('test.echo', { prefix: '>>' }, {
                onChunk: (e) => {
                  got.push(e.echo);
                  if (got.length === 2) { window.__result = JSON.stringify(got); sess.close(); }
                },
                onError: (err) => { window.__result = 'ERR: ' + err.message; },
              });
              // Push two client frames into the open session.
              sess.push({ text: 'a' });
              sess.push({ text: 'b' });
            </script></body></html>
            """
            adapter.webView.loadHTMLString(html, baseURL: nil)

            let result = try await waitForJSResult(in: adapter)
            #expect(result == #"[">>a",">>b"]"#)
        }

        /// End-to-end SPA history-routing fallback: a deep-link to a
        /// client-side route with no file on disk must serve the bundle
        /// entry (index.html) through the real `pwa://` scheme handler,
        /// rather than failing the navigation. Proves the wiring from
        /// `setBundleRoot(spaFallback:)` → `WKSchemeHandler` → a rendered
        /// page, not just the resolver in isolation.
        @Test("spa fallback serves the entry for a deep-link route through a real WKWebView")
        func spaFallbackDeepLink() async throws {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("swift-pwa-spa-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            // index.html carries a recognizable <title> marker.
            try Data("<!doctype html><html><head><title>SPA_ROOT</title></head><body>ok</body></html>".utf8)
                .write(to: dir.appendingPathComponent("index.html"))

            let provider = AssetProvider()
            provider.setBundleRoot(dir, spaFallback: true, fallbackDocument: "index.html")

            let cfg = WKWebViewConfiguration()
            WKWebViewAdapter.registerScheme("pwa", on: cfg, assetProvider: provider)
            let adapter = try WKWebViewAdapter(configuration: cfg)

            // Hard-load a nested client-side route that names no file on disk.
            let route = try #require(URL(string: "pwa://localhost/settings/deep"))
            adapter.webView.load(URLRequest(url: route))

            let title = try await waitForJSExpr(in: adapter, "document.title")
            #expect(title == "SPA_ROOT")
        }

        /// A document's bridge state must not outlive the document. Navigating
        /// the same window to a second page used to leave the first page's
        /// `events.subscribe` streams running natively, so one `emit` was
        /// delivered once per document ever loaded in that window — and, worse,
        /// the leaked stream's frames carried the *old* document's correlation
        /// ids, which the new document resolved against its own table.
        @Test("a second document does not inherit the first document's streams")
        func navigationDoesNotLeakSubscriptions() async throws {
            let app = MockAppContext()
            app.use(EventsPlugin())
            app.registry.register("ping", typed: { (_: EmptyArgs, _) -> EmptyResult in EmptyResult() })

            let adapter = try WKWebViewAdapter(configuration: WKWebViewConfiguration())
            let win = MockWindow(webView: adapter)
            app.attach(win)

            let bridge = BridgeRuntime(
                webView: adapter,
                registry: app.registry,
                windowID: win.id,
                app: app
            )
            bridge.start()
            defer { bridge.stop() }

            func page(_ marker: String) -> String {
                """
                <!doctype html><html><head><meta charset="utf-8"></head><body>
                <script>
                  window.__doc = '\(marker)';
                  window.__count = 0;
                  window.__ready = null;
                  __SWIFT_PWA__.on('chan', () => { window.__count++; });
                  __SWIFT_PWA__.invoke('ping').then(() => { window.__ready = 'yes'; });
                </script></body></html>
                """
            }

            for marker in ["A", "B", "C"] {
                adapter.webView.loadHTMLString(page(marker), baseURL: nil)
                let ready = try await waitForJSExpr(
                    in: adapter,
                    "(window.__doc === '\(marker)' && window.__ready) ? 'ok' : null"
                )
                #expect(ready == "ok", "document \(marker) never became ready")
            }

            try app.events.emit("chan", ["n": 1])
            // Give any leaked stream time to deliver a duplicate.
            try await Task.sleep(for: .milliseconds(400))

            let count = try await adapter.evaluateJavaScript("window.__count")
            #expect(count == "1", "one emit reached the live document \(count ?? "nil") times")
        }

        /// The sharp edge of the leak: `bridge.js` allocates correlation ids
        /// from a per-document counter that restarts at 1, so a leaked stream
        /// keeps emitting frames stamped with ids the *new* document has since
        /// reused for something else. Here the first document subscribes one
        /// channel and the second subscribes two in the other order, which is
        /// enough to slide them a slot apart — the leaked channel's payload
        /// then lands in the wrong handler.
        @Test("a leaked stream cannot bind to a new document's subscription")
        func navigationDoesNotMisrouteFrames() async throws {
            let app = MockAppContext()
            app.use(EventsPlugin())
            app.registry.register("ping", typed: { (_: EmptyArgs, _) -> EmptyResult in EmptyResult() })

            let adapter = try WKWebViewAdapter(configuration: WKWebViewConfiguration())
            let win = MockWindow(webView: adapter)
            app.attach(win)

            let bridge = BridgeRuntime(
                webView: adapter,
                registry: app.registry,
                windowID: win.id,
                app: app
            )
            bridge.start()
            defer { bridge.stop() }

            // Document one: `prefs` takes id 1.
            let first = """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
            <script>
              window.__doc = 'one';
              window.__ready = null;
              __SWIFT_PWA__.on('prefs', () => {});
              __SWIFT_PWA__.invoke('ping').then(() => { window.__ready = 'yes'; });
            </script></body></html>
            """
            // Document two: an extra invoke first, so `denied` takes id 1 here —
            // the slot document one gave to `prefs`.
            let second = """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
            <script>
              window.__doc = 'two';
              window.__ready = null;
              window.__wrong = 0;
              __SWIFT_PWA__.on('denied', () => { window.__wrong++; });
              __SWIFT_PWA__.invoke('ping').then(() => { window.__ready = 'yes'; });
            </script></body></html>
            """

            adapter.webView.loadHTMLString(first, baseURL: nil)
            _ = try await waitForJSExpr(in: adapter, "(window.__doc === 'one' && window.__ready) ? 'ok' : null")
            adapter.webView.loadHTMLString(second, baseURL: nil)
            let ready = try await waitForJSExpr(in: adapter, "(window.__doc === 'two' && window.__ready) ? 'ok' : null")
            #expect(ready == "ok")

            // Nothing in the live document listens to `prefs`.
            try app.events.emit("prefs", ["key": "galleryScroll"])
            try await Task.sleep(for: .milliseconds(400))

            let wrong = try await adapter.evaluateJavaScript("window.__wrong")
            #expect(wrong == "0", "a prefs payload was delivered to the denied handler \(wrong ?? "nil") times")
        }

        /// `bridge.js` is injected into subframes as well as the main frame, so
        /// a subframe minting its own epoch and announcing it would read as "the
        /// window navigated" and cancel the *parent's* subscriptions. Only the
        /// top frame takes part in the epoch protocol; this pins that down.
        @Test("an iframe loading does not tear down the parent document's streams")
        func subframeDoesNotCountAsANavigation() async throws {
            let app = MockAppContext()
            app.use(EventsPlugin())
            app.registry.register("ping", typed: { (_: EmptyArgs, _) -> EmptyResult in EmptyResult() })

            let adapter = try WKWebViewAdapter(configuration: WKWebViewConfiguration())
            let win = MockWindow(webView: adapter)
            app.attach(win)

            let bridge = BridgeRuntime(
                webView: adapter,
                registry: app.registry,
                windowID: win.id,
                app: app
            )
            bridge.start()
            defer { bridge.stop() }

            let html = """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
            <iframe srcdoc="<p>embedded</p>"></iframe>
            <script>
              window.__count = 0;
              window.__ready = null;
              __SWIFT_PWA__.on('chan', () => { window.__count++; });
              __SWIFT_PWA__.invoke('ping').then(() => { window.__ready = 'yes'; });
            </script></body></html>
            """
            adapter.webView.loadHTMLString(html, baseURL: nil)
            _ = try await waitForJSExpr(in: adapter, "window.__ready")
            // Let the subframe finish loading and run its injected copy. Assert
            // it really got one — otherwise this test passes for the wrong
            // reason the day subframe injection stops happening.
            try await Task.sleep(for: .milliseconds(300))
            let inFrame = try await adapter.evaluateJavaScript(
                "document.querySelector('iframe').contentWindow.__SWIFT_PWA__ ? 'yes' : 'no'"
            )
            #expect(unwrapJSONString(inFrame ?? "") == "yes", "the subframe never got bridge.js")

            try app.events.emit("chan", ["n": "1"])
            try await Task.sleep(for: .milliseconds(300))

            let count = try await adapter.evaluateJavaScript("window.__count")
            #expect(count == "1", "the parent's subscription saw the emit \(count ?? "nil") times")
        }
    }

    private struct EchoArgs: Codable, Equatable {
        let value: String
    }

    private struct SessionOpen: Codable { let prefix: String }
    private struct SessionFrame: Codable { let text: String }
    private struct SessionEvent: Codable { let echo: String }

    @MainActor
    private func waitForJSResult(
        in adapter: WKWebViewAdapter,
        timeout: Duration = .seconds(5)
    ) async throws -> String? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let value = try await adapter.evaluateJavaScript("window.__result")
            // WKWebView returns the literal "<null>" string (or nil) when
            // the value is null/undefined.
            if let value, value != "<null>", value != "(null)" {
                return unwrapJSONString(value)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// `evaluateJavaScript` returns the **JSON serialization** of the result,
    /// so a JS string arrives quoted and escaped (`"{\"a\":1}"`), matching
    /// WebKitGTK's `jsc_value_to_json`. These tests set `window.__result` to a
    /// stringified envelope, so decode one level to get the payload back.
    private func unwrapJSONString(_ value: String) -> String {
        guard value.hasPrefix("\""),
              let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8))
        else { return value }
        return decoded
    }

    /// Poll an arbitrary JS expression until it evaluates to a non-empty,
    /// non-null string (or the timeout elapses). Used to wait for a page to
    /// finish loading and expose a marker (e.g. `document.title`).
    @MainActor
    private func waitForJSExpr(
        in adapter: WKWebViewAdapter,
        _ expr: String,
        timeout: Duration = .seconds(5)
    ) async throws -> String? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let value = try await adapter.evaluateJavaScript(expr)
            if let value, value != "<null>", value != "(null)" {
                let unwrapped = unwrapJSONString(value)
                if !unwrapped.isEmpty { return unwrapped }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
#endif
