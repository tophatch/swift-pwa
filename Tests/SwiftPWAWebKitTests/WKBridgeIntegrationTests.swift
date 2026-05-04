#if canImport(WebKit) && (os(macOS) || os(iOS))
    import Foundation
    import Testing
    import WebKit
    import _SwiftPWATestSupport
    @testable import SwiftPWACore
    @testable import SwiftPWAWebKit

    @Suite("WKWebView ↔ Swift round-trip")
    @MainActor
    struct WKBridgeIntegrationTests {
        /// Spins up a real WKWebView, registers an `echo` command, loads
        /// an HTML fixture that calls `__SWIFT_PWA__.invoke('echo', ...)`,
        /// and verifies the reply arrives back in JS.
        @Test("invoke echo round-trips through a real WKWebView")
        func echoRoundTrip() async throws {
            let app = MockAppContext()
            await app.registry.register("echo", typed: { (args: EchoArgs, _) -> EchoArgs in args })

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
    }

    private struct EchoArgs: Codable, Sendable, Equatable {
        let value: String
    }

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
                return value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
#endif
