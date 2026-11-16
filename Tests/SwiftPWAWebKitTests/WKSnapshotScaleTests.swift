#if canImport(WebKit) && os(macOS)
    import AppKit
    import Foundation
    @testable import SwiftPWACore
    @testable import SwiftPWAWebKit
    import Testing
    import WebKit

    /// `window.snapshot`'s `scale` on the Apple backend (#344): WebKit renders
    /// the picture at the smaller size, so the bitmap that reaches the encode is
    /// already small. Read back from the PNG, not trusted from the call.
    @Suite("snapshot scale — WKWebView")
    @MainActor
    struct WKSnapshotScaleTests {
        @Test("scale shrinks the whole picture and a region of it, from the full size")
        func scales() async throws {
            let adapter = try await loadedAdapter()
            let full = try #require(try await PNGDimensions.read(withTimeout { try await adapter.captureSnapshot() }))
            let half = try #require(try await PNGDimensions.read(withTimeout {
                try await adapter.captureSnapshot(region: nil, scale: 0.5)
            }))
            #expect(abs(half.width - full.width / 2) <= 1)
            #expect(abs(half.height - full.height / 2) <= 1)

            let region = SnapshotRegion(
                rect: Rect(x: 0, y: 0, width: 100, height: 50),
                viewport: Size(width: 400, height: 300)
            )
            let regionFull = try #require(try await PNGDimensions.read(withTimeout {
                try await adapter.captureSnapshot(region: region, scale: 1)
            }))
            let regionQuarter = try #require(try await PNGDimensions.read(withTimeout {
                try await adapter.captureSnapshot(region: region, scale: 0.25)
            }))
            #expect(abs(regionQuarter.width - regionFull.width / 4) <= 1)
            #expect(abs(regionQuarter.height - regionFull.height / 4) <= 1)
        }

        private func loadedAdapter() async throws -> WKWebViewAdapter {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("swift-pwa-snapshot-scale-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("""
            <!doctype html><style>html,body{margin:0;height:100%;background:#0000ff}</style>
            <div style="width:50%;height:50%;background:#ff0000"></div>
            """.utf8).write(to: root.appendingPathComponent("index.html"))
            let provider = AssetProvider()
            provider.setBundleRoot(root)
            let configuration = WKWebViewConfiguration()
            WKWebViewAdapter.registerScheme("pwa", on: configuration, assetProvider: provider)
            let adapter = try WKWebViewAdapter(configuration: configuration)
            // Never ordered on screen: a CI runner with no window server takes
            // the whole test process down for that (see WKMediaPlaybackTests).
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            window.isReleasedWhenClosed = false
            window.contentView = adapter.webView
            Self.windows.append(window)
            adapter.webView.load(URLRequest(url: URL(string: "pwa://localhost/index.html")!))
            let deadline = ContinuousClock.now + .seconds(20)
            while ContinuousClock.now < deadline {
                if try await adapter.evaluateJavaScript("document.readyState") == "\"complete\"" { return adapter }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw BridgeError(code: BridgeError.handler, message: "the test page never loaded")
        }

        /// A snapshot that never answers fails the test instead of hanging it.
        private func withTimeout(_ body: @escaping @MainActor () async throws -> Data) async throws -> Data {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { try await body() }
                group.addTask {
                    try await Task.sleep(for: .seconds(20))
                    throw BridgeError(code: BridgeError.handler, message: "the snapshot never answered")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        }

        /// Kept alive for the process, as in WKMediaPlaybackTests: a window
        /// released while its web view is loading crashes a later test.
        @MainActor private static var windows: [NSWindow] = []
    }
#endif
