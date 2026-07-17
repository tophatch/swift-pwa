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
            let window = NSWindow(
                contentRect: rect,
                styleMask: style,
                backing: .buffered,
                defer: false
            )
            window.title = config.title
            if let min = config.minSize { window.contentMinSize = NSSize(width: min.width, height: min.height) }
            if let max = config.maxSize { window.contentMaxSize = NSSize(width: max.width, height: max.height) }
            // A remembered position (via `rememberState`) or an explicit
            // `config.origin` overrides centring; the origin is a bottom-left
            // frame origin, matching `position()` / `setPosition(_:)` so it
            // round-trips.
            if let origin = config.origin {
                window.setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
            } else {
                window.center()
            }
            window.contentView = adapter.webView

            // Native background before first paint: avoids the white flash
            // and colours the overscroll / rubber-band area.
            if let hex = config.backgroundColor, let rgb = RGBColor(hex: hex) {
                let color = NSColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
                window.backgroundColor = color
                adapter.webView.underPageBackgroundColor = color
                adapter.webView.wantsLayer = true
                adapter.webView.layer?.backgroundColor = color.cgColor
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
            bridge.start()

            adapter.load(config.content)
            if config.fullscreen { window.toggleFullScreen(nil) }
            if config.visibleOnLaunch { window.makeKeyAndOrderFront(nil) }
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

        public func focus() { nsWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        public func minimize() { nsWindow.miniaturize(nil) }
        public func maximize() { nsWindow.zoom(nil) }
        public func setFullscreen(_ on: Bool) {
            let isFs = nsWindow.styleMask.contains(.fullScreen)
            if on != isFs { nsWindow.toggleFullScreen(nil) }
        }
        public func isFullscreen() -> Bool { nsWindow.styleMask.contains(.fullScreen) }

        public func close() { nsWindow.performClose(nil) }

        // MARK: - NSWindowDelegate

        public func windowWillClose(_ notification: Notification) {
            emit(.willClose)
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

        public func windowShouldClose(_ sender: NSWindow) -> Bool { true }
    }
#endif
