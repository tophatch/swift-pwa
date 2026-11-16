#if canImport(WebKit) && os(macOS)
    import Foundation
    @testable import SwiftPWACore
    @testable import SwiftPWAWebKit
    import Testing
    import WebKit

    /// The page half of #349, run against a real media element: `bridge.js`
    /// with a media route points the app's media URLs at a
    /// ``LoopbackMediaServer`` and reads them back as the app's own.
    ///
    /// Only the GTK backends route media — their player can't read `pwa://` —
    /// and WebKitGTK can't run here, so this uses the same script and server
    /// under macOS WebKit. What it can't show is GStreamer accepting the
    /// result; the Linux bundle-smoke job and `Scripts/verify-linux-media.sh`
    /// do that.
    @Suite("media route — app media through the loopback server")
    @MainActor
    struct WKMediaRouteTests {
        @Test("markup, src, setAttribute, <source> and new Audio all load through the server")
        func everyWayIn() async throws {
            let site = try WKMediaPlaybackTests.ClipSite()
            defer { site.remove() }
            let provider = AssetProvider()
            let server = try LoopbackMediaServer.start(provider: provider)
            defer { server.stop() }
            let adapter = try site.load(
                provider: provider,
                mediaRoute: BridgeScript.MediaRoute(base: server.baseURL, origin: "pwa://localhost")
            )
            #expect(try await site.waitForMetadata(adapter))

            // The markup's <video> loaded, and it was the server it loaded from.
            #expect(try await adapter.evaluateJavaScript("v.outerHTML.includes(\(json(server.baseURL)))") == "true")
            let reads = try await string(adapter, "[v.src, v.currentSrc, v.getAttribute('src')].join(' ')")
            #expect(reads == "pwa://localhost/clip.mp4 pwa://localhost/clip.mp4 clip.mp4")

            _ = try await adapter.evaluateJavaScript("""
            window.made = {};
            made.prop = document.createElement('video'); made.prop.src = 'clip.mp4';
            made.attr = document.createElement('video'); made.attr.setAttribute('src', 'clip.mp4');
            const holder = document.createElement('div');
            holder.innerHTML = '<video><source src="clip.mp4" type="video/mp4"></video>';
            document.body.append(made.prop, made.attr, holder);
            made.inner = holder.firstChild;
            made.audio = new Audio('clip.mp4');
            for (const el of Object.values(made)) { el.muted = true; el.preload = 'auto'; el.load(); }
            1
            """)
            let loaded = try await poll(adapter, "Object.values(made).every(el => el.readyState >= 1)")
            #expect(loaded)
            let current = try await string(adapter, "Object.values(made).map(el => el.currentSrc).join(' ')")
            #expect(current == Array(repeating: "pwa://localhost/clip.mp4", count: 4).joined(separator: " "))
            #expect(try await adapter
                .evaluateJavaScript("made.audio instanceof Audio && made.audio instanceof HTMLAudioElement") == "true")
            let sourceSrc = try await string(adapter, "made.inner.querySelector('source').src")
            #expect(sourceSrc == "pwa://localhost/clip.mp4")
        }

        @Test("a crossorigin frame from the server stays readable to the app")
        func canvasStaysReadable() async throws {
            let site = try WKMediaPlaybackTests.ClipSite()
            defer { site.remove() }
            let provider = AssetProvider()
            let server = try LoopbackMediaServer.start(provider: provider)
            defer { server.stop() }
            let adapter = try site.load(
                provider: provider,
                mediaRoute: BridgeScript.MediaRoute(base: server.baseURL, origin: "pwa://localhost")
            )
            #expect(try await site.waitForMetadata(adapter))
            _ = try await adapter.evaluateJavaScript("""
            window.cv = document.createElement('video'); cv.crossOrigin = 'anonymous'; cv.muted = true;
            cv.src = 'clip.mp4'; document.body.append(cv); 1
            """)
            #expect(try await poll(adapter, "cv.readyState >= 2"))
            #expect(try await adapter.evaluateJavaScript("""
            (() => { const c = document.createElement('canvas'); c.width = c.height = 4;
              const g = c.getContext('2d'); g.drawImage(cv, 0, 0, 4, 4);
              try { g.getImageData(0, 0, 1, 1); return 'readable'; } catch (e) { return e.name; } })()
            """) == "\"readable\"")
        }

        @Test("without a route nothing is rewritten")
        func noRoute() async throws {
            let site = try WKMediaPlaybackTests.ClipSite()
            defer { site.remove() }
            let adapter = try site.load()
            #expect(try await site.waitForMetadata(adapter))
            #expect(try await adapter.evaluateJavaScript("v.outerHTML.includes('127.0.0.1')") == "false")
            #expect(try await adapter
                .evaluateJavaScript("Element.prototype.getAttribute.toString().includes('[native code]')") == "true")
        }

        private func poll(_ adapter: WKWebViewAdapter, _ condition: String) async throws -> Bool {
            let deadline = ContinuousClock.now + .seconds(20)
            while ContinuousClock.now < deadline {
                if try await adapter.evaluateJavaScript(condition) == "true" { return true }
                try await Task.sleep(for: .milliseconds(50))
            }
            return false
        }

        /// A string result, decoded: the adapter answers JSON, which writes
        /// `/` as `\/`, so matching its text against a URL fails on a right
        /// answer.
        private func string(_ adapter: WKWebViewAdapter, _ script: String) async throws -> String? {
            guard let json = try await adapter.evaluateJavaScript(script) else { return nil }
            return try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed) as? String
        }

        private func json(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
    }
#endif
