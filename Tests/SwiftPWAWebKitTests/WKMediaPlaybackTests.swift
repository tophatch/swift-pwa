#if canImport(WebKit) && (os(macOS) || os(iOS))
    import Foundation
    @testable import SwiftPWACore
    @testable import SwiftPWAWebKit
    import Testing
    import WebKit

    /// What a page's `<video>` may do, asked of a real `WKWebView` with a clip
    /// loaded (#347, #348). WebKit answers the presentation-mode questions
    /// `false` for a video with no media yet, whatever the configuration
    /// allows, so every check waits on `readyState` first.
    @Suite("media playback — fullscreen and picture in picture")
    @MainActor
    struct WKMediaPlaybackTests {
        @Test("element fullscreen is on, so a <video> can go fullscreen")
        func fullscreenAvailable() async throws {
            let site = try ClipSite()
            defer { site.remove() }
            let adapter = try site.load()
            #expect(try await site.waitForMetadata(adapter))
            #expect(try await adapter.evaluateJavaScript("document.fullscreenEnabled") == "true")
            #expect(try await adapter.evaluateJavaScript("typeof v.requestFullscreen") == "\"function\"")
            #expect(try await adapter.evaluateJavaScript(
                "v.webkitSupportsPresentationMode('fullscreen')"
            ) == "true")
        }

        #if os(macOS)
            @Test("picture in picture stays off on macOS unless the app opted in")
            func pictureInPictureOffByDefault() async throws {
                let site = try ClipSite()
                defer { site.remove() }
                let adapter = try site.load()
                #expect(try await site.waitForMetadata(adapter))
                #expect(try await adapter.evaluateJavaScript(
                    "v.webkitSupportsPresentationMode('picture-in-picture')"
                ) == "false")
            }

            @Test("macos.picture_in_picture turns picture in picture on")
            func pictureInPictureOptIn() async throws {
                let site = try ClipSite()
                defer { site.remove() }
                let adapter = try site.load(pictureInPicture: true)
                #expect(try await site.waitForMetadata(adapter))
                #expect(try await adapter.evaluateJavaScript(
                    "v.webkitSupportsPresentationMode('picture-in-picture')"
                ) == "true")
            }
        #else
            @Test("picture in picture is on, and a <video> plays inline")
            func iOSDefaults() async throws {
                let site = try ClipSite()
                defer { site.remove() }
                let adapter = try site.load()
                #expect(try await site.waitForMetadata(adapter))
                #expect(adapter.webView.configuration.allowsInlineMediaPlayback)
                #expect(try await adapter.evaluateJavaScript(
                    "v.webkitSupportsPresentationMode('picture-in-picture')"
                ) == "true")
            }
        #endif

        /// A served directory holding a page with one `<video>` and its clip.
        private struct ClipSite {
            let root: URL

            init() throws {
                root = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("swift-pwa-media-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data(base64Encoded: Self.clip, options: .ignoreUnknownCharacters)!
                    .write(to: root.appendingPathComponent("clip.mp4"))
                try Data("""
                <!doctype html><video id=v src="clip.mp4" playsinline muted controls></video>
                <script>const v = document.getElementById('v');</script>
                """.utf8).write(to: root.appendingPathComponent("index.html"))
            }

            /// `pictureInPicture` stands in for the app's opt-in, which the
            /// adapter reads from a bundle the test process doesn't have.
            @MainActor
            func load(pictureInPicture: Bool = false) throws -> WKWebViewAdapter {
                let provider = AssetProvider()
                provider.setBundleRoot(root)
                let configuration = WKWebViewConfiguration()
                WKWebViewAdapter.registerScheme("pwa", on: configuration, assetProvider: provider)
                if pictureInPicture { WKMediaPlayback.configure(configuration, pictureInPicture: true) }
                let adapter = try WKWebViewAdapter(configuration: configuration)
                host(adapter.webView)
                adapter.webView.load(URLRequest(url: URL(string: "pwa://localhost/index.html")!))
                return adapter
            }

            /// WebKit doesn't start loading media for a view that isn't in a
            /// window. The window is never ordered on screen: a CI runner with
            /// no window server takes the whole test process down for that.
            @MainActor
            private func host(_ webView: WKWebView) {
                #if os(macOS)
                    let window = NSWindow(
                        contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                        styleMask: [.titled],
                        backing: .buffered,
                        defer: true
                    )
                    window.isReleasedWhenClosed = false
                    window.contentView = webView
                #else
                    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
                    window.addSubview(webView)
                #endif
                Self.windows.append(window)
            }

            /// Kept alive for the process: a window released while its web
            /// view is still loading is a crash in a later, unrelated test.
            @MainActor private static var windows: [AnyObject] = []

            /// The control: without it a `false` above could just mean the clip
            /// never loaded.
            @MainActor
            func waitForMetadata(_ adapter: WKWebViewAdapter) async throws -> Bool {
                let deadline = ContinuousClock.now + .seconds(20)
                while ContinuousClock.now < deadline {
                    if try await adapter.evaluateJavaScript("typeof v !== 'undefined' && v.readyState >= 1") == "true" {
                        return true
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                return false
            }

            func remove() {
                try? FileManager.default.removeItem(at: root)
            }

            /// One second of a 16×16 grey H.264 clip (1.6 KB).
            private static let clip = """
            AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAMybW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAA+gAAQAAAQAA
            AAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAA
            Al10cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAA+gAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAA
            AAAAAAAAAAAAAABAAAAAABAAAAAQAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAPoAAAAAAABAAAAAAHVbWRpYQAAACBtZGhk
            AAAAAAAAAAAAAAAAAABAAAAAQABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABgG1p
            bmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAUBzdGJsAAAAwHN0c2QA
            AAAAAAAAAQAAALBhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAABAAEABIAAAASAAAAAAAAAABFExhdmM2My4xLjEwMSBsaWJ4
            MjY0AAAAAAAAAAAAAAAAGP//AAAANmF2Y0MBZAAK/+EAGWdkAAqscgRewEQAAAMABAAAAwAQPEiWEYABAAZo6EOPLIv9+PgAAAAA
            EHBhc3AAAAABAAAAAQAAABRidHJ0AAAAAAAAFpAAAAAAAAAAGHN0dHMAAAAAAAAAAQAAAAIAACAAAAAAFHN0c3MAAAAAAAAAAQAA
            AAEAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAIAAAABAAAAHHN0c3oAAAAAAAAAAAAAAAIAAALFAAAADQAAABRzdGNvAAAAAAAAAAEA
            AANiAAAAYXVkdGEAAABZbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAsaWxzdAAAACSpdG9vAAAA
            HGRhdGEAAAABAAAAAExhdmY2My4xLjEwMQAAAAhmcmVlAAAC2m1kYXQAAAKvBgX//6vcRem95tlIt5Ys2CDZI+7veDI2NCAtIGNv
            cmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDov
            L3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MSByZWY9MTYgZGVibG9jaz0xOjA6MCBhbmFseXNl
            PTB4MzoweDEzMyBtZT11bWggc3VibWU9MTAgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MSBtZV9yYW5nZT0yNCBj
            aHJvbWFfbWU9MSB0cmVsbGlzPTIgOHg4ZGN0PTEgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9v
            ZmZzZXQ9LTIgdGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50
            ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9OCBiX3B5cmFtaWQ9MiBiX2FkYXB0
            PTIgYl9iaWFzPTAgZGlyZWN0PTMgd2VpZ2h0Yj0xIG9wZW5fZ29wPTAgd2VpZ2h0cD0yIGtleWludD0yNTAga2V5aW50X21pbj0y
            IHNjZW5lY3V0PTQwIGludHJhX3JlZnJlc2g9MCByY19sb29rYWhlYWQ9NjAgcmM9Y3JmIG1idHJlZT0xIGNyZj0yMy4wIHFjb21w
            PTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTE6MS4wMACAAAAADmWIgQACn/73x0/Anthh
            AAAACUGaCC2IJf/+4A==
            """
        }
    }
#endif
