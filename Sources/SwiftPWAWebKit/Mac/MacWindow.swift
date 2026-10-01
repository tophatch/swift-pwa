#if os(macOS)
    import AppKit
    import Foundation
    import SwiftPWACore
    import WebKit

    /// macOS `Window` implementation: NSWindow + WKWebView, with a
    /// delegate that translates AppKit window events into our
    /// cross-platform `WindowEvent` enum.
    @MainActor
    public final class MacWindow: NSObject, Window, NSWindowDelegate {
        public let id = WindowID()
        public let webView: any PWAWebView

        private let nsWindow: NSWindow
        private let adapter: WKWebViewAdapter
        private let bridge: BridgeRuntime
        private weak var app: MacAppContext?

        private var continuations: [UUID: AsyncStream<WindowEvent>.Continuation] = [:]
        /// Kept alive only for a light/dark background pair: a `CGColor` is a
        /// snapshot of one appearance, so the webview layer's fill is the one
        /// place AppKit can't re-resolve for us.
        private var appearanceObservation: NSKeyValueObservation?
        /// The page's departure, started by the first of a close or a quit to
        /// reach this window; the other one awaits the same work.
        private var preparation: Task<Void, Never>?
        /// Set once the page has finished and the window may really close.
        private var mayClose = false
        private var closeRequested = false
        private var didEmitWillClose = false

        public init(config: WindowConfig, app: MacAppContext) throws {
            // Configure WKWebView with pwa:// scheme handler if we'll
            // need it. We set up the handler before creating the
            // adapter so it gets baked into the configuration.
            let cfg = WKWebViewConfiguration()
            if case let .bundled(directory, entry, spaFallback) = config.content {
                // Share the context-level router so runtime `serveDirectory`
                // mounts are visible to this window's scheme handler.
                app.assetProvider.setBundleRoot(directory, spaFallback: spaFallback, fallbackDocument: entry)
                WKWebViewAdapter.registerScheme("pwa", on: cfg, assetProvider: app.assetProvider)
            }
            let adapter = try WKWebViewAdapter(configuration: cfg)
            self.adapter = adapter
            webView = adapter

            let style: NSWindow.StyleMask = config.resizable
                ? [.titled, .closable, .miniaturizable, .resizable]
                : [.titled, .closable, .miniaturizable]
            let rect = NSRect(
                x: 0, y: 0,
                width: config.size.width,
                height: config.size.height
            )
            // A driver build uses a window subclass that suppresses the
            // unhandled-key alert beep for events the driver itself injected —
            // see DriverWindow. Everything else about it is a plain NSWindow.
            #if SWIFT_PWA_DRIVER
                let window = DriverWindow(
                    contentRect: rect,
                    styleMask: style,
                    backing: .buffered,
                    defer: false
                )
                // Parking a window off screen needs AppKit's constraining
                // switched off, or it drags a titled window straight back onto
                // a display. Only in a backgrounded run: a window that's merely
                // driven is still a window the user may be looking at, and it
                // should keep every normal placement rule.
                window.allowsOffscreenPlacement = DriverBackground.isRequested
            #else
                let window = NSWindow(
                    contentRect: rect,
                    styleMask: style,
                    backing: .buffered,
                    defer: false
                )
            #endif
            window.title = config.title
            if let min = config.minSize { window.contentMinSize = NSSize(width: min.width, height: min.height) }
            if let max = config.maxSize { window.contentMaxSize = NSSize(width: max.width, height: max.height) }
            // A remembered position (via `rememberState`) or an explicit
            // `config.origin` overrides centring; the origin is a bottom-left
            // frame origin, matching `position()` / `setPosition(_:)` so it
            // round-trips.
            if DriverBackground.isRequested {
                // Off screen rather than merely behind everything: a covered
                // window still costs stacking order, still flickers through
                // Mission Control and the window list, and would do so once per
                // test file. It is genuinely ordered in, though — `orderOut`
                // stops WebKit servicing the page.
                window.setFrameOrigin(NSPoint(x: DriverBackground.parkedOrigin.x, y: DriverBackground.parkedOrigin.y))
            } else if let origin = config.origin {
                window.setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
            } else {
                window.center()
            }
            window.contentView = adapter.webView

            // Native background before first paint: avoids the white flash
            // and colours the overscroll / rubber-band area. A light/dark pair
            // becomes a dynamic NSColor so AppKit re-resolves it when the
            // system appearance changes.
            let backgroundColor = config.backgroundColor?.nsColor()
            if let color = backgroundColor {
                window.backgroundColor = color
                adapter.webView.underPageBackgroundColor = color
                adapter.webView.wantsLayer = true
                Self.applyLayerBackground(color, to: adapter.webView, in: window)
            }

            nsWindow = window
            self.app = app

            bridge = BridgeRuntime(
                webView: adapter,
                registry: app.registry,
                windowID: id,
                app: app
            )

            super.init()
            window.delegate = self
            if let color = backgroundColor, config.backgroundColor?.isPair == true {
                appearanceObservation = window.observe(\.effectiveAppearance) { [weak adapter] window, _ in
                    MainActor.assumeIsolated {
                        guard let webView = adapter?.webView else { return }
                        MacWindow.applyLayerBackground(color, to: webView, in: window)
                    }
                }
            }
            bridge.start()

            // Before `load`, so the first navigation is policed too.
            adapter.attachWebPolicy(policy: app.externalURLs, opener: AppleURLOpener())
            adapter.load(config.content)
            if config.fullscreen { window.toggleFullScreen(nil) }
            if config.visibleOnLaunch {
                // `orderFrontRegardless` rather than `makeKeyAndOrderFront` in a
                // backgrounded run: the window has to be in the window list for
                // WebKit to keep rendering it, but making it key would pull the
                // app in front of whatever the user is doing.
                if DriverBackground.isRequested {
                    Self.orderInWithoutActivating(window)
                } else {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }

        /// Windows a backgrounded run has asked to order in before the app
        /// finished launching, and the observer that orders them in once it has.
        private(set) static var windowsAwaitingLaunch: [NSWindow] = []
        private static var launchObserver: (any NSObjectProtocol)?

        /// Order `window` in for a backgrounded run — in the window list, so
        /// WebKit keeps servicing it, without making it key or activating the
        /// app.
        ///
        /// **Not before launch has finished.** AppKit activates a launching app
        /// that already has a window ordered in when it finishes launching
        /// (`-[NSApplication _sendFinishLaunchingNotification]`, inside
        /// `NSApp.run()`), whatever its activation policy and however the
        /// window was ordered in — `.accessory`, a non-activating panel,
        /// `orderBack` all lose the same way. It only shows when the process
        /// that launched the app is frontmost, which is exactly a suite started
        /// from an editor's terminal (#283). A window ordered in once launch
        /// has finished doesn't activate anything, so a window created during
        /// `configure` waits for that one notification.
        static func orderInWithoutActivating(_ window: NSWindow) {
            guard NSApp?.isRunning != true else {
                window.orderFrontRegardless()
                return
            }
            windowsAwaitingLaunch.append(window)
            guard launchObserver == nil else { return }
            launchObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    for window in windowsAwaitingLaunch { window.orderFrontRegardless() }
                    windowsAwaitingLaunch.removeAll()
                    if let launchObserver { NotificationCenter.default.removeObserver(launchObserver) }
                    launchObserver = nil
                }
            }
        }

        /// Resolve `color` against the window's current appearance and paint
        /// the webview's backing layer with it. `NSView.layer` takes a
        /// `CGColor`, which carries no appearance of its own, so the value has
        /// to be resolved while that appearance is the drawing one.
        static func applyLayerBackground(_ color: NSColor, to view: NSView, in window: NSWindow) {
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                view.layer?.backgroundColor = color.cgColor
            }
        }

        // MARK: - Window

        public func eventStream() -> AsyncStream<WindowEvent> {
            let key = UUID()
            return AsyncStream { continuation in
                self.continuations[key] = continuation
                continuation.onTermination = { @Sendable _ in
                    Task { @MainActor in self.continuations.removeValue(forKey: key) }
                }
            }
        }

        private func emit(_ event: WindowEvent) {
            for c in continuations.values { c.yield(event) }
        }

        public func setTitle(_ title: String) { nsWindow.title = title }
        public func title() -> String { nsWindow.title }

        public func setSize(_ size: Size, animated: Bool) {
            var frame = nsWindow.frame
            frame.size = NSSize(width: size.width, height: size.height)
            nsWindow.setFrame(frame, display: true, animate: animated)
        }
        public func size() -> Size {
            let s = nsWindow.contentLayoutRect.size
            return Size(width: Double(s.width), height: Double(s.height))
        }

        public func setPosition(_ point: Point) {
            nsWindow.setFrameOrigin(NSPoint(x: point.x, y: point.y))
        }
        public func position() -> Point {
            let o = nsWindow.frame.origin
            return Point(x: Double(o.x), y: Double(o.y))
        }

        /// In a backgrounded run this orders the window in without making it
        /// key and without activating the app.
        ///
        /// Not inert, because `window.focus` has a second meaning a driven page
        /// actually depends on: it is how a page asks to be *rendered*, and
        /// three of the adopter's test files poll it until `!document.hidden`
        /// for exactly that reason. Ordering in satisfies that (the page reports
        /// `visible` and rAF runs at full rate with occlusion detection off),
        /// while raising the app would undo the whole mode — 37 times a run.
        public func focus() {
            guard !DriverBackground.isRequested else {
                Self.orderInWithoutActivating(nsWindow)
                return
            }
            nsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        public func minimize() { nsWindow.miniaturize(nil) }
        public func maximize() { nsWindow.zoom(nil) }
        public func setFullscreen(_ on: Bool) {
            let isFs = nsWindow.styleMask.contains(.fullScreen)
            if on != isFs { nsWindow.toggleFullScreen(nil) }
        }
        public func isFullscreen() -> Bool { nsWindow.styleMask.contains(.fullScreen) }

        /// `NSWindow.occlusionState` is AppKit's own answer to "is any of this
        /// window actually on screen" — it accounts for being covered by another
        /// window, being on an inactive Space, and the display being asleep, all
        /// of which stop WebKit servicing `requestAnimationFrame`. Miniaturized
        /// windows report `.visible` in some macOS versions, so check that too.
        public func visibility() -> WindowVisibility {
            // A backgrounded run answers the question this enum is actually for
            // — "is WebKit still servicing this window" — rather than "is it on
            // screen". Occlusion detection is off there, so a parked window
            // renders at full rate and reporting the screen truth (`hidden`)
            // would send a harness looking for a rendering bug that isn't
            // there. Being ordered in is the line that still matters.
            if DriverBackground.isActive {
                return nsWindow.isVisible ? .visible : .hidden
            }
            if nsWindow.isMiniaturized { return .hidden }
            return nsWindow.occlusionState.contains(.visible) ? .visible : .hidden
        }

        public func close() { nsWindow.performClose(nil) }

        public func prepareToClose(until deadline: ContinuousClock.Instant) async {
            if preparation == nil {
                emitWillCloseOnce()
                nsWindow.orderOut(nil)
                preparation = Task { @MainActor [bridge, adapter] in
                    await bridge.letDocumentFinish(until: deadline) {
                        adapter.load(.remote(Closing.departureURL))
                    }
                }
            }
            await preparation?.value
        }

        private func emitWillCloseOnce() {
            guard !didEmitWillClose else { return }
            didEmitWillClose = true
            emit(.willClose)
        }

        // MARK: - NSWindowDelegate

        /// The close button, ⌘W and `window.close` all arrive here. The first
        /// time, the window is taken off screen and the close deferred until
        /// the page has finished and the app's `beforeClose` handlers have
        /// run; then it closes for real, without asking again.
        public func windowShouldClose(_: NSWindow) -> Bool {
            guard !mayClose else { return true }
            guard !closeRequested else { return false }
            closeRequested = true
            let deadline = ContinuousClock.now + CloseBudget.window
            Task { @MainActor [weak self] in
                guard let self else { return }
                await prepareToClose(until: deadline)
                await CloseHandlers.shared.run(.window(id), until: deadline)
                mayClose = true
                nsWindow.close()
            }
            return false
        }

        public func windowWillClose(_ notification: Notification) {
            // A window closed during `configure` must not be ordered back in
            // when launch finishes.
            Self.windowsAwaitingLaunch.removeAll { $0 === nsWindow }
            emitWillCloseOnce()
            // NSWindow has no `didClose` delegate hook — post a tick later
            // so observers see willClose before didClose.
            Task { @MainActor [weak self] in
                guard let self else { return }
                emit(.didClose)
                for c in continuations.values { c.finish() }
                continuations.removeAll()
                bridge.stop()
                app?.windowDidClose(id)
            }
        }

        public nonisolated func windowDidResize(_ notification: Notification) {
            Task { @MainActor [weak self] in self?.emit(.didResize(self?.size() ?? .zero)) }
        }

        public nonisolated func windowDidMove(_ notification: Notification) {
            Task { @MainActor [weak self] in self?.emit(.didMove(self?.position() ?? .zero)) }
        }

        public nonisolated func windowDidBecomeKey(_ notification: Notification) {
            Task { @MainActor [weak self] in self?.emit(.didFocus) }
        }

        public nonisolated func windowDidResignKey(_ notification: Notification) {
            Task { @MainActor [weak self] in self?.emit(.didBlur) }
        }

        public nonisolated func windowDidEnterFullScreen(_ notification: Notification) {
            Task { @MainActor [weak self] in self?.emit(.didEnterFullscreen) }
        }

        public nonisolated func windowDidExitFullScreen(_ notification: Notification) {
            Task { @MainActor [weak self] in self?.emit(.didExitFullscreen) }
        }

        public nonisolated func windowDidMiniaturize(_ notification: Notification) {
            Task { @MainActor [weak self] in self?.emit(.didMinimize) }
        }

        public nonisolated func windowDidDeminiaturize(_ notification: Notification) {
            Task { @MainActor [weak self] in self?.emit(.didDeminiaturize) }
        }
    }
#endif
