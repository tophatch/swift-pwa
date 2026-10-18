#if canImport(WebKit) && os(macOS)
    import Foundation
    import SwiftPWACore
    import Testing
    import WebKit

    /// The script WebView2 injects so a page's viewport tag stops a pinch
    /// (#304), run here in a real WebKit page: the decision it makes from the
    /// tag doesn't depend on the engine, and this is the engine CI can run.
    @Suite("Viewport tag zoom script")
    @MainActor
    struct ViewportZoomScriptTests {
        private struct Outcome: Decodable, Equatable {
            let sheet: Bool
            let ctrlWheelCancelled: Bool
            let plainWheelCancelled: Bool
        }

        private func outcome(viewport: String?) async throws -> Outcome {
            let config = WKWebViewConfiguration()
            config.userContentController.addUserScript(WKUserScript(
                source: ViewportZoom.script, injectionTime: .atDocumentStart, forMainFrameOnly: true
            ))
            let webView = WKWebView(frame: .zero, configuration: config)
            let meta = viewport.map { #"<meta name="viewport" content="\#($0)">"# } ?? ""
            webView.loadHTMLString("<!doctype html><html><head>\(meta)</head><body>x</body></html>", baseURL: nil)
            let probe = """
            const wheel = (ctrlKey) => {
              const event = new WheelEvent('wheel', { ctrlKey, cancelable: true, deltaY: -10 });
              dispatchEvent(event);
              return event.defaultPrevented;
            };
            return JSON.stringify({
              sheet: document.adoptedStyleSheets.some((s) => [...s.cssRules].some((r) => r.cssText.includes('pan-x pan-y'))),
              ctrlWheelCancelled: wheel(true),
              plainWheelCancelled: wheel(false),
            });
            """
            // The page's own body, not just a complete document: the web view
            // starts on a blank one that is already complete.
            var loaded = false
            for _ in 0 ..< 100 where !loaded {
                let state = "document.readyState === 'complete' && document.body?.textContent === 'x'"
                loaded = await (try? webView.evaluateJavaScript(state) as? Bool) == true
                if !loaded { try await Task.sleep(for: .milliseconds(50)) }
            }
            try #require(loaded, "the test page never loaded")
            let json = try #require(try await webView.callAsyncJavaScript(probe, contentWorld: .page) as? String)
            return try JSONDecoder().decode(Outcome.self, from: Data(json.utf8))
        }

        @Test("a tag that rules out zoom stops a pinch, and only a pinch", arguments: [
            "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no",
            "width=device-width, user-scalable=no",
            "width=device-width, user-scalable=0",
            "width=device-width; maximum-scale=1.0",
            "WIDTH=device-width, USER-SCALABLE=NO"
        ])
        func forbidden(viewport: String) async throws {
            let result = try await outcome(viewport: viewport)
            #expect(result == Outcome(sheet: true, ctrlWheelCancelled: true, plainWheelCancelled: false))
        }

        @Test("a page that allows zoom, or says nothing, is left alone", arguments: [
            nil,
            "width=device-width, initial-scale=1",
            "width=device-width, initial-scale=1, viewport-fit=cover",
            "width=device-width, user-scalable=yes",
            "width=device-width, maximum-scale=5"
        ])
        func allowed(viewport: String?) async throws {
            let result = try await outcome(viewport: viewport)
            #expect(result == Outcome(sheet: false, ctrlWheelCancelled: false, plainWheelCancelled: false))
        }
    }
#endif
