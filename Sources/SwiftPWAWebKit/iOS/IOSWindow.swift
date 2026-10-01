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
            if case let .bundled(directory, entry, spaFallback) = config.content {
                app.assetProvider.setBundleRoot(directory, spaFallback: spaFallback, fallbackDocument: entry)
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
            // A light/dark pair becomes a dynamic UIColor, so UIKit re-resolves
            // it when the system appearance changes under a running app —
            // otherwise a dark-themed app bounces paper white on every
            // overscroll.
            if let color = config.backgroundColor?.uiColor() {
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
            // Before `load`, so the first navigation is policed too.
            adapter.attachWebPolicy(policy: app.externalURLs, opener: AppleURLOpener())
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

        /// Closes once the page has finished and the app's `beforeClose`
        /// handlers have run (#281), then destroys the scene.
        public func close() {
            guard !closeRequested else { return }
            closeRequested = true
            let deadline = ContinuousClock.now + CloseBudget.window
            Task { @MainActor [weak self] in
                guard let self else { return }
                await prepareToClose(until: deadline)
                await CloseHandlers.shared.run(.window(id), until: deadline)
                if let session = uiWindow?.windowScene?.session {
                    UIApplication.shared.requestSceneSessionDestruction(session, options: nil, errorHandler: nil)
                }
                emit(.didClose)
                for c in continuations.values { c.finish() }
                continuations.removeAll()
                bridge.stop()
                app?.windowDidClose(id)
            }
        }

        /// A scene can't be hidden before it goes, so the page's last frame
        /// is laid over the web view while it navigates away — otherwise the
        /// blank document it departs to would flash on screen first.
        public func prepareToClose(until deadline: ContinuousClock.Instant) async {
            if preparation == nil {
                emit(.willClose)
                let webView = adapter.webView
                if let cover = webView.snapshotView(afterScreenUpdates: false) {
                    cover.frame = webView.bounds
                    webView.addSubview(cover)
                }
                preparation = Task { @MainActor [bridge, adapter] in
                    await bridge.letDocumentFinish(until: deadline) {
                        adapter.load(.remote(Closing.departureURL))
                    }
                }
            }
            await preparation?.value
        }

        /// The app went to the background: let what the page posted as it
        /// went hidden finish.
        func finishPageForBackground(until deadline: ContinuousClock.Instant) async {
            await bridge.finishGoingHidden(until: deadline)
        }

        private var preparation: Task<Void, Never>?
        private var closeRequested = false
    }
#endif
