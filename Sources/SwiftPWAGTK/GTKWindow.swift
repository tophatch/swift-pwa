#if os(Linux)
    import CGtk3Shim
    import CWebKitGTK4Shim
    import Foundation
    import SwiftPWACore

    /// GTK3 + WebKitGTK 4.1 implementation of `Window`.
    ///
    /// This file is intentionally a thin Swift wrapper around the C
    /// API exposed by `CGtk3Shim` / `CWebKitGTK4Shim`. We hand-roll
    /// the bindings rather than pulling in a community Swift-GTK
    /// wrapper to keep the dependency surface tiny and decouple our
    /// release cadence from theirs.
    @MainActor
    public final class GTKWindow: Window {
        public let id = WindowID()
        public let webView: any PWAWebView

        // Owned C handles. The `OpaquePointer`s are GtkWindow / WebKitWebView.
        private let gtkWindow: OpaquePointer
        private let adapter: WebKitGTKAdapter
        private let bridge: BridgeRuntime
        private weak var app: GTKAppContext?
        private var titleStorage: String
        private var continuations: [UUID: AsyncStream<WindowEvent>.Continuation] = [:]

        public init(config: WindowConfig, app: GTKAppContext) throws {
            // gtk_window_new(GTK_WINDOW_TOPLEVEL == 0)
            guard let win = gtk_window_new(GTK_WINDOW_TOPLEVEL) else {
                throw BridgeError(code: BridgeError.handler, message: "gtk_window_new failed")
            }
            self.gtkWindow = OpaquePointer(win)

            config.title.withCString { gtk_window_set_title(self.gtkWindow, $0) }
            gtk_window_set_default_size(
                self.gtkWindow,
                gint(config.size.width),
                gint(config.size.height)
            )
            gtk_window_set_resizable(self.gtkWindow, config.resizable ? gboolean(1) : gboolean(0))

            self.titleStorage = config.title

            let adapter = try WebKitGTKAdapter(parent: self.gtkWindow, content: config.content)
            self.adapter = adapter
            self.webView = adapter
            self.app = app

            self.bridge = BridgeRuntime(
                webView: adapter,
                registry: app.registry,
                windowID: id,
                app: app
            )
            bridge.start()
            adapter.load(config.content)

            if config.fullscreen { gtk_window_fullscreen(self.gtkWindow) }
            if config.visibleOnLaunch { gtk_widget_show_all(UnsafeMutablePointer(self.gtkWindow)) }
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

        func emit(_ event: WindowEvent) {
            for c in continuations.values { c.yield(event) }
        }

        public func setTitle(_ title: String) {
            titleStorage = title
            title.withCString { gtk_window_set_title(gtkWindow, $0) }
        }
        public func title() -> String { titleStorage }

        public func setSize(_ size: Size, animated _: Bool) {
            gtk_window_resize(gtkWindow, gint(size.width), gint(size.height))
            emit(.didResize(size))
        }
        public func size() -> Size {
            var w: gint = 0
            var h: gint = 0
            gtk_window_get_size(gtkWindow, &w, &h)
            return Size(width: Double(w), height: Double(h))
        }

        public func setPosition(_ point: Point) {
            gtk_window_move(gtkWindow, gint(point.x), gint(point.y))
            emit(.didMove(point))
        }
        public func position() -> Point {
            var x: gint = 0
            var y: gint = 0
            gtk_window_get_position(gtkWindow, &x, &y)
            return Point(x: Double(x), y: Double(y))
        }

        public func focus() {
            gtk_window_present(gtkWindow)
            emit(.didFocus)
        }
        public func minimize() {
            gtk_window_iconify(gtkWindow)
            emit(.didMinimize)
        }
        public func maximize() {
            gtk_window_maximize(gtkWindow)
        }
        public func setFullscreen(_ on: Bool) {
            if on { gtk_window_fullscreen(gtkWindow) } else { gtk_window_unfullscreen(gtkWindow) }
            emit(on ? .didEnterFullscreen : .didExitFullscreen)
        }
        public func isFullscreen() -> Bool {
            // We don't observe state changes here; track at higher level if needed.
            false
        }

        public func close() {
            emit(.willClose)
            gtk_widget_destroy(UnsafeMutablePointer(gtkWindow))
            emit(.didClose)
            for c in continuations.values { c.finish() }
            continuations.removeAll()
            bridge.stop()
            app?.windowDidClose(id)
        }
    }
#endif
