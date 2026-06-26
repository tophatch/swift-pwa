#if os(iOS)
    import Foundation
    import SwiftPWACore
    import UIKit
    import WebKit

    /// iOS `Window` implementation. A `UIWindow` plus a single
    /// view controller hosting a `WKWebView` via `WKWebViewAdapter`.
    ///
    /// The actual `UIWindow` is supplied by `SwiftPWASceneDelegate`
    /// when a scene connects; until then the window is "pending" and
    /// only its `webView` and `bridge` are live.
    @MainActor
    public final class IOSWindow: Window {
        public let id = WindowID()
        public let webView: any PWAWebView

        var uiWindow: UIWindow? // attached lazily by SceneDelegate
        let viewController: UIViewController
        let adapter: WKWebViewAdapter
        private let bridge: BridgeRuntime
        private weak var app: IOSAppContext?
        private var titleStorage: String
        private var continuations: [UUID: AsyncStream<WindowEvent>.Continuation] = [:]

        public init(config: WindowConfig, app: IOSAppContext) throws {
            let cfg = WKWebViewConfiguration()
            if case let .bundled(directory, _) = config.content {
                app.assetProvider.setBundleRoot(directory)
                WKWebViewAdapter.registerScheme("pwa", on: cfg, assetProvider: app.assetProvider)
            }
            let adapter = try WKWebViewAdapter(configuration: cfg)
            self.adapter = adapter
            webView = adapter

            let vc = UIViewController()
            vc.view = adapter.webView
            viewController = vc
            titleStorage = config.title
            vc.title = config.title

            // Native background before first paint: kills the white/black
            // flash and colours the scroll overscroll (rubber-band) area.
            if let hex = config.backgroundColor, let rgb = RGBColor(hex: hex) {
                let color = UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
                adapter.webView.isOpaque = false
                adapter.webView.backgroundColor = color
                adapter.webView.scrollView.backgroundColor = color
                adapter.webView.underPageBackgroundColor = color
                vc.view.backgroundColor = color
            }

            self.app = app
            bridge = BridgeRuntime(
                webView: adapter,
                registry: app.registry,
                windowID: id,
                app: app
            )
            bridge.start()
            adapter.load(config.content)
        }

        public func eventStream() -> AsyncStream<WindowEvent> {
            let key = UUID()
            return AsyncStream { continuation in
                self.continuations[key] = continuation
                continuation.onTermination = { @Sendable _ in
                    Task { @MainActor in self.continuations.removeValue(forKey: key) }
                }
            }
        }

        func emit(_ event: WindowEvent) {
            for c in continuations.values { c.yield(event) }
        }

        // MARK: - Window

        public func setTitle(_ title: String) {
            titleStorage = title
            viewController.title = title
        }
        public func title() -> String { titleStorage }

        public func setSize(_ size: Size, animated _: Bool) {
            // iOS windows fill their scene; size is informational only.
            uiWindow?.bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        }
        public func size() -> Size {
            let s = uiWindow?.bounds.size ?? .zero
            return Size(width: Double(s.width), height: Double(s.height))
        }

        public func setPosition(_: Point) { /* no-op on iOS */ }
        public func position() -> Point { .zero }

        public func focus() {
            uiWindow?.makeKeyAndVisible()
            emit(.didFocus)
        }
        public func minimize() { /* no-op on iOS */ }
        public func maximize() { /* no-op on iOS */ }
        public func setFullscreen(_ on: Bool) {
            // iOS apps are inherently full-screen; emit the events
            // anyway so JS observers see consistent behavior.
            emit(on ? .didEnterFullscreen : .didExitFullscreen)
        }
        public func isFullscreen() -> Bool { false }

        public func close() {
            emit(.willClose)
            if let session = uiWindow?.windowScene?.session {
                UIApplication.shared.requestSceneSessionDestruction(
                    session,
                    options: nil,
                    errorHandler: nil
                )
            }
            emit(.didClose)
            for c in continuations.values { c.finish() }
            continuations.removeAll()
            bridge.stop()
            app?.windowDidClose(id)
        }
    }
#endif
