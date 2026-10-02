#if os(iOS)
    import Foundation
    import SwiftPWACore
    import UIKit
    import WebKit

    /// iOS `Window` implementation. A `UIWindow` plus a single
    /// view controller hosting a `WKWebView` via `WKWebViewAdapter`.
    ///
    /// The actual `UIWindow` is supplied when its scene connects (see
    /// ``IOSAppContext/createWindow(_:)``); until then the window is
    /// "pending" and only its `webView` and `bridge` are live.
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

        /// `restoring` is the page to show instead of the config's entry, for
        /// a window the system is bringing back (see ``RestoredPage``).
        public init(config: WindowConfig, app: IOSAppContext, restoring: URL? = nil) throws {
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
            adapter.load(RestoredPage.content(config.content, restoring: restoring))
        }

        func attach(to scene: UIWindowScene) {
            let uiWindow = UIWindow(windowScene: scene)
            uiWindow.rootViewController = viewController
            self.uiWindow = uiWindow
            uiWindow.makeKeyAndVisible()
            recordPage(in: scene.session)
            // Every page and every in-page route change, not only on going to
            // the background: an app can end without getting there.
            pageObservation = adapter.webView.observe(\.url) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let session = self.uiWindow?.windowScene?.session else { return }
                    self.recordPage(in: session)
                }
            }
        }

        private var pageObservation: NSKeyValueObservation?
        private static let lastPageKey = "swift-pwa.page"

        /// Remembers the page on the scene's session, which outlives both a
        /// scene the system disconnects to reclaim memory and the app itself.
        func recordPage(in session: UISceneSession) {
            guard !closeRequested, let url = adapter.webView.url else { return }
            session.userInfo = [Self.lastPageKey: url.absoluteString]
        }

        static func lastPage(in session: UISceneSession) -> URL? {
            (session.userInfo?[lastPageKey] as? String).flatMap(URL.init(string:))
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

        /// A window fills its scene, and the scene's size is the user's to set.
        /// Setting the `UIWindow`'s bounds instead shrank the page inside its
        /// own window and left the rest of the scene black.
        public func setSize(_: Size, animated _: Bool) {}
        public func size() -> Size {
            let s = uiWindow?.bounds.size ?? .zero
            return Size(width: Double(s.width), height: Double(s.height))
        }

        public func setPosition(_: Point) { /* no-op on iOS */ }
        public func position() -> Point { .zero }

        public func focus() {
            // A scene that isn't in front only comes forward when the system
            // is asked to activate it; making its window key does nothing.
            if UIApplication.shared.supportsMultipleScenes, let session = uiWindow?.windowScene?.session {
                UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: session))
            }
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
            finish(destroyingScene: true)
        }

        /// The system took the scene away: the user closed the window from the
        /// system UI, or iPadOS reclaimed a background scene's memory. The web
        /// view outlives its scene, so the page still departs and gets its
        /// `pagehide` off screen, and `beforeClose(.window)` runs. A reclaimed
        /// scene that comes back gets a new window, showing the page this one
        /// recorded.
        func sceneDidDisconnect() {
            finish(destroyingScene: false)
        }

        private func finish(destroyingScene: Bool) {
            guard !closeRequested else { return }
            closeRequested = true
            let deadline = ContinuousClock.now + CloseBudget.window
            let task = BackgroundTask(named: "swift-pwa window close")
            Task { @MainActor [weak self] in
                defer { task.end() }
                guard let self else { return }
                await prepareToClose(until: deadline)
                await CloseHandlers.shared.run(.window(id), until: deadline)
                if destroyingScene, let session = uiWindow?.windowScene?.session {
                    UIApplication.shared.requestSceneSessionDestruction(session, options: nil, errorHandler: nil)
                }
                pageObservation = nil
                uiWindow = nil
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
