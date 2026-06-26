#if os(Linux)
    import CGtk4Shim
    import CWebKitGTK6Shim
    import Foundation
    import SwiftPWACore

    /// GTK4 + WebKitGTK 6.0 implementation of `Window`.
    ///
    /// Mirrors the GTK3 backend's `GTKWindow` but adapted to the GTK4
    /// API: `close-request` instead of `delete-event`, `gtk_window_set_child`
    /// instead of `gtk_container_add`, `gtk_window_destroy` instead of
    /// `gtk_widget_destroy`, and a `GtkShortcutController` for Ctrl+Q
    /// instead of `GtkAccelGroup`.
    ///
    /// **Position is not supported.** GTK4 dropped the position APIs
    /// entirely (Wayland refuses to give apps their own position; CSD
    /// makes the concept ambiguous anyway). `position()` returns
    /// `.zero`, `setPosition()` is a no-op, and `.didMove` events are
    /// never emitted. See the `Window` protocol's docstring for the
    /// best-effort contract.
    @MainActor
    public final class GTKWindow: Window {
        public let id = WindowID()
        public let webView: any PWAWebView

        /// The owned `GtkWidget*` (concretely a `GtkWindow`).
        private let widget: UnsafeMutablePointer<GtkWidget>
        private let adapter: WebKitGTKAdapter
        private let bridge: BridgeRuntime
        private weak var app: GTKAppContext?
        private var titleStorage: String
        private var continuations: [UUID: AsyncStream<WindowEvent>.Continuation] = [:]

        /// Last size seen via the `default-width` / `default-height`
        /// notify signals. We only emit `.didResize` when the value
        /// actually changes — both properties fire independently
        /// during a drag.
        private var lastSize: Size = .zero

        /// Cast our owned widget back to `GtkWindow*` for `gtk_window_*` calls.
        private var window: UnsafeMutablePointer<GtkWindow> {
            UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkWindow.self)
        }

        /// Internal accessor for sibling backend code (e.g. `SystemDialog`)
        /// that needs to parent a transient dialog onto this window.
        var nativeWindow: UnsafeMutablePointer<GtkWindow> {
            window
        }

        public init(config: WindowConfig, app: GTKAppContext) throws {
            guard let win = gtk_window_new() else {
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

            let adapter = try WebKitGTKAdapter(content: config.content, sharedProvider: app.assetProvider)
            self.adapter = adapter
            webView = adapter

            // Place the WebKit view inside the window. GTK4 windows have
            // exactly one child slot.
            gtk_window_set_child(windowPtr, adapter.viewWidget)

            // Native background before first paint (no white flash).
            if let hex = config.backgroundColor, let rgb = RGBColor(hex: hex) {
                adapter.setBackgroundColor(rgb)
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

            if config.fullscreen { gtk_window_fullscreen(windowPtr) }
            if config.visibleOnLaunch { gtk_widget_set_visible(win, gboolean(1)) }

            lastSize = config.size
            connectSizeNotify()
            connectCloseRequest()
            swiftpwa_window_install_quit_shortcut(windowPtr, quitShortcutCallback, nil)
            // Pass `self` as the DevTools shortcut's user_data so the
            // trampoline can dispatch back into this window's adapter.
            // Lifetime is fine: the controller dies with the window.
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            swiftpwa_window_install_devtools_shortcut(windowPtr, devToolsShortcutCallback, selfPtr)
        }

        /// Connect the `default-width` / `default-height` notify signals
        /// so user-driven WM resizes surface as `WindowEvent.didResize`.
        /// GTK4 doesn't have a `configure-event` analogue; the canonical
        /// way to observe geometry changes is through these properties.
        private func connectSizeNotify() {
            let box = Unmanaged.passRetained(GTKWindowBox(self)).toOpaque()
            "notify::default-width".withCString { name in
                _ = g_signal_connect_data(
                    UnsafeMutableRawPointer(widget),
                    name,
                    unsafeBitCast(notifySizeTrampoline, to: GCallback.self),
                    box,
                    gtkWindowBoxDestroy,
                    GConnectFlags(rawValue: 0)
                )
            }
            // Second connection shares the same box; retain again so
            // the destroy notify on each connection is balanced.
            let box2 = Unmanaged.passRetained(GTKWindowBox(self)).toOpaque()
            "notify::default-height".withCString { name in
                _ = g_signal_connect_data(
                    UnsafeMutableRawPointer(widget),
                    name,
                    unsafeBitCast(notifySizeTrampoline, to: GCallback.self),
                    box2,
                    gtkWindowBoxDestroy,
                    GConnectFlags(rawValue: 0)
                )
            }
        }

        /// Hook `close-request` so a user-driven [X] / Alt+F4 / WM-close
        /// runs the same teardown as a programmatic `close()`. Returning
        /// FALSE from the trampoline lets GTK's default handler destroy
        /// the window.
        private func connectCloseRequest() {
            let box = Unmanaged.passRetained(GTKWindowBox(self)).toOpaque()
            "close-request".withCString { name in
                _ = g_signal_connect_data(
                    UnsafeMutableRawPointer(widget),
                    name,
                    unsafeBitCast(closeRequestTrampoline, to: GCallback.self),
                    box,
                    gtkWindowBoxDestroy,
                    GConnectFlags(rawValue: 0)
                )
            }
        }

        /// Called from the size notify trampoline. Reads the actual
        /// current allocation rather than trusting either property
        /// individually — `default-width` fires before `default-height`,
        /// so emitting on each individually would yield a half-changed
        /// size.
        func handleSizeNotify() {
            let w = Double(gtk_widget_get_width(widget))
            let h = Double(gtk_widget_get_height(widget))
            let size = Size(width: w, height: h)
            if size != lastSize {
                lastSize = size
                emit(.didResize(size))
            }
        }

        /// Called from the close-request trampoline when the user
        /// closes via the WM. GTK is about to destroy the widget; we
        /// run the same teardown as `close()` minus the destroy call.
        func handleCloseRequest() {
            emit(.willClose)
            emit(.didClose)
            cleanupAfterClose()
        }

        private func cleanupAfterClose() {
            for c in continuations.values { c.finish() }
            continuations.removeAll()
            bridge.stop()
            app?.windowDidClose(id)
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
            // GTK4 has no separate "resize" call; setting the default
            // size requests it from the compositor. The notify signals
            // fire when the WM acks and `handleSizeNotify` emits.
            gtk_window_set_default_size(window, gint(size.width), gint(size.height))
        }
        public func size() -> Size {
            let w = Double(gtk_widget_get_width(widget))
            let h = Double(gtk_widget_get_height(widget))
            return Size(width: w, height: h)
        }

        public func setPosition(_: Point) {
            // GTK4 dropped position APIs entirely. No-op by design —
            // see the `Window` protocol docstring.
        }
        public func position() -> Point { .zero }

        public func focus() {
            gtk_window_present(window)
            emit(.didFocus)
        }
        public func minimize() {
            gtk_window_minimize(window)
            emit(.didMinimize)
        }
        public func maximize() {
            gtk_window_maximize(window)
        }
        public func setFullscreen(_ on: Bool) {
            if on { gtk_window_fullscreen(window) } else { gtk_window_unfullscreen(window) }
            emit(on ? .didEnterFullscreen : .didExitFullscreen)
        }
        public func isFullscreen() -> Bool { false }

        public func close() {
            emit(.willClose)
            gtk_window_destroy(window)
            emit(.didClose)
            cleanupAfterClose()
        }
    }

    /// Heap box holding a back-reference to the window for GObject
    /// signal callbacks. Released by `gtkWindowBoxDestroy` when the
    /// signal is disconnected (i.e. when the GtkWindow is destroyed).
    final class GTKWindowBox {
        weak var window: GTKWindow?
        init(_ window: GTKWindow) { self.window = window }
    }

    /// `@convention(c)` GClosureNotify that releases the heap-boxed
    /// `GTKWindowBox` when the signal is disconnected.
    let gtkWindowBoxDestroy: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = {
        userData, _ in
        guard let userData else { return }
        Unmanaged<GTKWindowBox>.fromOpaque(userData).release()
    }

    /// `@convention(c)` trampoline for `notify::default-width` and
    /// `notify::default-height`. The full GObject notify signature is
    /// `(GObject*, GParamSpec*, gpointer)`; we ignore both inputs and
    /// re-read the widget's current allocation.
    let notifySizeTrampoline: @convention(c) (
        gpointer?,
        gpointer?,
        gpointer?
    ) -> Void = { _, _, userData in
        guard let userData else { return }
        let userDataRaw = UInt(bitPattern: userData)
        MainActor.assumeIsolated {
            guard let opaque = UnsafeMutableRawPointer(bitPattern: userDataRaw) else { return }
            let box = Unmanaged<GTKWindowBox>.fromOpaque(opaque).takeUnretainedValue()
            box.window?.handleSizeNotify()
        }
    }

    /// `@convention(c)` trampoline for `close-request`. Returns FALSE
    /// so GTK's default handler proceeds with `gtk_window_destroy`.
    let closeRequestTrampoline: @convention(c) (
        UnsafeMutablePointer<GtkWindow>?,
        gpointer?
    ) -> gboolean = { _, userData in
        guard let userData else { return gboolean(0) }
        let userDataRaw = UInt(bitPattern: userData)
        MainActor.assumeIsolated {
            guard let opaque = UnsafeMutableRawPointer(bitPattern: userDataRaw) else { return }
            let box = Unmanaged<GTKWindowBox>.fromOpaque(opaque).takeUnretainedValue()
            box.window?.handleCloseRequest()
        }
        return gboolean(0)
    }

    /// `@convention(c)` callback wired to Ctrl+Q via the shortcut
    /// controller. Fires on the GTK main thread; quits the shared
    /// `GTKAppContext`, which stops the GMainLoop.
    let quitShortcutCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in
        MainActor.assumeIsolated {
            GTKAppContext.shared.quit(exitCode: 0)
        }
    }

    /// `@convention(c)` callback wired to Ctrl+Alt+J. `user_data` is
    /// the unretained `GTKWindow` pointer set up at shortcut install
    /// time; we resolve it back and call `webView.openDevTools()` for
    /// just that window.
    let devToolsShortcutCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { userData in
        guard let userData else { return }
        let userDataRaw = UInt(bitPattern: userData)
        MainActor.assumeIsolated {
            guard let opaque = UnsafeMutableRawPointer(bitPattern: userDataRaw) else { return }
            let window = Unmanaged<GTKWindow>.fromOpaque(opaque).takeUnretainedValue()
            window.webView.openDevTools()
        }
    }
#endif
