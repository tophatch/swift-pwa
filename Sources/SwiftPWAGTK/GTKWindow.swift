#if os(Linux)
    import CGtk3Shim
    import CWebKitGTK4Shim
    import Foundation
    import SwiftPWACore

    /// GTK3 + WebKitGTK 4.1 implementation of `Window`.
    ///
    /// Hand-rolled bindings: GTK widgets share an inheritance chain
    /// (`GtkWidget` → `GtkWindow`) backed by the same memory layout via
    /// GObject. Swift's Clang importer types each typedef as a distinct
    /// `UnsafeMutablePointer<_GtkXxx>` though, so we store the widget
    /// pointer once and rebind to the concrete type at each call site.
    @MainActor
    public final class GTKWindow: Window {
        public let id = WindowID()
        public let webView: any PWAWebView

        /// The owned `GtkWidget*` (concretely a top-level `GtkWindow`).
        private let widget: UnsafeMutablePointer<GtkWidget>
        private let adapter: WebKitGTKAdapter
        private let bridge: BridgeRuntime
        private weak var app: GTKAppContext?
        private var titleStorage: String
        private var continuations: [UUID: AsyncStream<WindowEvent>.Continuation] = [:]

        /// Cast our owned widget back to `GtkWindow*` for `gtk_window_*` calls.
        private var window: UnsafeMutablePointer<GtkWindow> {
            UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkWindow.self)
        }

        public init(config: WindowConfig, app: GTKAppContext) throws {
            guard let win = gtk_window_new(GTK_WINDOW_TOPLEVEL) else {
                throw BridgeError(code: BridgeError.handler, message: "gtk_window_new failed")
            }
            widget = win

            let windowPtr = UnsafeMutableRawPointer(win).assumingMemoryBound(to: GtkWindow.self)
            config.title.withCString { gtk_window_set_title(windowPtr, $0) }
            gtk_window_set_default_size(
                windowPtr,
                gint(config.size.width),
                gint(config.size.height)
            )
            gtk_window_set_resizable(windowPtr, config.resizable ? gboolean(1) : gboolean(0))

            titleStorage = config.title

            let adapter = try WebKitGTKAdapter(parent: win, content: config.content)
            self.adapter = adapter
            webView = adapter
            self.app = app

            bridge = BridgeRuntime(
                webView: adapter,
                registry: app.registry,
                windowID: id,
                app: app
            )
            bridge.start()
            adapter.load(config.content)

            if config.fullscreen { gtk_window_fullscreen(windowPtr) }
            if config.visibleOnLaunch { gtk_widget_show_all(win) }
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
            title.withCString { gtk_window_set_title(window, $0) }
        }
        public func title() -> String { titleStorage }

        public func setSize(_ size: Size, animated _: Bool) {
            gtk_window_resize(window, gint(size.width), gint(size.height))
            emit(.didResize(size))
        }
        public func size() -> Size {
            var w: gint = 0
            var h: gint = 0
            gtk_window_get_size(window, &w, &h)
            return Size(width: Double(w), height: Double(h))
        }

        public func setPosition(_ point: Point) {
            gtk_window_move(window, gint(point.x), gint(point.y))
            emit(.didMove(point))
        }
        public func position() -> Point {
            var x: gint = 0
            var y: gint = 0
            gtk_window_get_position(window, &x, &y)
            return Point(x: Double(x), y: Double(y))
        }

        public func focus() {
            gtk_window_present(window)
            emit(.didFocus)
        }
        public func minimize() {
            gtk_window_iconify(window)
            emit(.didMinimize)
        }
        public func maximize() {
            gtk_window_maximize(window)
        }
        public func setFullscreen(_ on: Bool) {
            if on { gtk_window_fullscreen(window) } else { gtk_window_unfullscreen(window) }
            emit(on ? .didEnterFullscreen : .didExitFullscreen)
        }
        public func isFullscreen() -> Bool {
            // We don't observe state changes here; track at a higher level if needed.
            false
        }

        public func close() {
            emit(.willClose)
            gtk_widget_destroy(widget)
            emit(.didClose)
            for c in continuations.values { c.finish() }
            continuations.removeAll()
            bridge.stop()
            app?.windowDidClose(id)
        }
    }
#endif
