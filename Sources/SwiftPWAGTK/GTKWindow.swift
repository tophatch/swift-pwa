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

        /// Last geometry seen via `configure-event`. We only emit
        /// `.didResize` / `.didMove` when the value actually changes —
        /// configure-event fires for every move *and* resize, sometimes
        /// in flurries when the user drags a corner.
        private var lastSize: Size = .zero
        private var lastPosition: Point = .zero

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

            lastSize = config.size
            connectConfigureSignal()
        }

        /// Hook GTK's `configure-event` so user-driven resizes / moves
        /// surface as `WindowEvent.didResize` / `.didMove`, matching
        /// the Mac `NSWindowDelegate` plumbing.
        private func connectConfigureSignal() {
            let box = Unmanaged.passRetained(GTKWindowBox(self)).toOpaque()
            "configure-event".withCString { name in
                _ = g_signal_connect_data(
                    UnsafeMutableRawPointer(widget),
                    name,
                    unsafeBitCast(configureEventTrampoline, to: GCallback.self),
                    box,
                    gtkWindowBoxDestroy,
                    GConnectFlags(rawValue: 0)
                )
            }
        }

        /// Called from the `configure-event` C trampoline (always on
        /// the GTK main thread) with the event's geometry.
        func handleConfigure(size: Size, position: Point) {
            if size != lastSize {
                lastSize = size
                emit(.didResize(size))
            }
            if position != lastPosition {
                lastPosition = position
                emit(.didMove(position))
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

        func emit(_ event: WindowEvent) {
            for c in continuations.values { c.yield(event) }
        }

        public func setTitle(_ title: String) {
            titleStorage = title
            title.withCString { gtk_window_set_title(window, $0) }
        }
        public func title() -> String { titleStorage }

        public func setSize(_ size: Size, animated _: Bool) {
            // GTK acks the resize asynchronously — `configure-event`
            // will fire and `handleConfigure` will emit `.didResize`.
            gtk_window_resize(window, gint(size.width), gint(size.height))
        }
        public func size() -> Size {
            var w: gint = 0
            var h: gint = 0
            gtk_window_get_size(window, &w, &h)
            return Size(width: Double(w), height: Double(h))
        }

        public func setPosition(_ point: Point) {
            // Same as setSize: configure-event will report the move.
            gtk_window_move(window, gint(point.x), gint(point.y))
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

    /// Heap box holding a back-reference to the window for GObject
    /// signal callbacks. Released by `gtkWindowBoxDestroy` when the
    /// signal is disconnected (i.e. when the GtkWindow is destroyed).
    final class GTKWindowBox {
        weak var window: GTKWindow?
        init(_ window: GTKWindow) { self.window = window }
    }

    /// `@convention(c)` trampoline for `configure-event`. Fires on the
    /// GTK main thread with the new geometry; we hop into the
    /// MainActor-isolated `GTKWindow.handleConfigure` to emit events.
    /// Returns `FALSE` so GTK propagates the event to default handlers.
    let configureEventTrampoline: @convention(c) (
        UnsafeMutablePointer<GtkWidget>?,
        gpointer?,
        gpointer?
    ) -> gboolean = { _, eventPtr, userData in
        guard let eventPtr, let userData else { return gboolean(0) }
        var x: Int32 = 0, y: Int32 = 0, w: Int32 = 0, h: Int32 = 0
        swiftpwa_event_configure_extents(eventPtr, &x, &y, &w, &h)
        let size = Size(width: Double(w), height: Double(h))
        let position = Point(x: Double(x), y: Double(y))
        // Launder the box pointer through `UInt` — the trampoline is
        // task-isolated, so capturing the raw `GTKWindowBox` reference
        // across into the MainActor closure trips Swift 6's
        // sending-risk diagnostic. Reconstituting the box *inside* the
        // MainActor isolation keeps the unsafe pointer crossing local.
        let userDataRaw = UInt(bitPattern: userData)
        MainActor.assumeIsolated {
            guard let opaque = UnsafeMutableRawPointer(bitPattern: userDataRaw) else { return }
            let box = Unmanaged<GTKWindowBox>.fromOpaque(opaque).takeUnretainedValue()
            box.window?.handleConfigure(size: size, position: position)
        }
        return gboolean(0)
    }

    /// `@convention(c)` GClosureNotify that releases the heap-boxed
    /// `GTKWindowBox` when the signal is disconnected.
    let gtkWindowBoxDestroy: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = {
        userData, _ in
        guard let userData else { return }
        Unmanaged<GTKWindowBox>.fromOpaque(userData).release()
    }
#endif
