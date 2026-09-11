#if os(Linux)
    import CGtk4Shim
    import Foundation

    /// The desktop's dark-mode preference, as GTK itself sees it, plus a
    /// change notification for windows painted with a light/dark background
    /// pair.
    ///
    /// `GtkSettings:gtk-application-prefer-dark-theme` is the property GTK
    /// acts on when it picks a theme variant, and it is what the desktop's
    /// own settings (and the XDG portal, through GTK) end up writing. We
    /// follow it rather than reading the portal directly so the native
    /// surface tracks the same signal the widgets around it do.
    ///
    /// The `notify::` handler is connected **once per process** — `GtkSettings`
    /// is app-global and outlives every window, so a per-window connection
    /// would accumulate handlers. Observers are held weakly and pruned, which
    /// also means a closed window needs no unregister call.
    @MainActor
    enum GTKAppearance {
        /// Whether GTK is currently asking applications to render dark.
        static var prefersDark: Bool {
            guard let settings = gtk_settings_get_default() else { return false }
            let object = UnsafeMutableRawPointer(settings).assumingMemoryBound(to: GObject.self)
            var value = GValue()
            g_value_init(&value, g_type_from_name("gboolean"))
            "gtk-application-prefer-dark-theme".withCString {
                g_object_get_property(object, $0, &value)
            }
            let dark = g_value_get_boolean(&value) != 0
            g_value_unset(&value)
            return dark
        }

        /// Test-only: stand in for the desktop's settings daemon, which is
        /// what writes this property for real. There is no such daemon under
        /// the bare Xvfb the GUI-gated tests run on.
        static func setPrefersDarkForTesting(_ dark: Bool) {
            guard let settings = gtk_settings_get_default() else { return }
            let object = UnsafeMutableRawPointer(settings).assumingMemoryBound(to: GObject.self)
            var value = GValue()
            g_value_init(&value, g_type_from_name("gboolean"))
            g_value_set_boolean(&value, dark ? gboolean(1) : gboolean(0))
            "gtk-application-prefer-dark-theme".withCString {
                g_object_set_property(object, $0, &value)
            }
            g_value_unset(&value)
        }

        private final class WeakWindow {
            weak var window: GTKWindow?
            init(_ window: GTKWindow) { self.window = window }
        }

        private static var observers: [WeakWindow] = []
        private static var connected = false

        /// Repaint `window`'s background whenever the preference changes.
        static func observe(_ window: GTKWindow) {
            connectIfNeeded()
            observers.removeAll { $0.window == nil }
            observers.append(WeakWindow(window))
        }

        /// Stop repainting `window` — its `WebKitWebView` is gone once the
        /// window closes, and painting a destroyed widget is a GTK
        /// `CRITICAL`, not a silent no-op. A weak reference isn't enough on
        /// its own: the Swift object can outlive the native widget.
        static func stopObserving(_ window: GTKWindow) {
            observers.removeAll { $0.window == nil || $0.window === window }
        }

        /// Called from the `notify::` trampoline on the GTK main thread.
        static func preferenceChanged() {
            observers.removeAll { $0.window == nil }
            for observer in observers { observer.window?.applyBackgroundForCurrentAppearance() }
        }

        private static func connectIfNeeded() {
            guard !connected, let settings = gtk_settings_get_default() else { return }
            connected = true
            "notify::gtk-application-prefer-dark-theme".withCString { name in
                _ = g_signal_connect_data(
                    UnsafeMutableRawPointer(settings),
                    name,
                    unsafeBitCast(appearanceNotifyTrampoline, to: GCallback.self),
                    nil,
                    nil,
                    GConnectFlags(rawValue: 0)
                )
            }
        }
    }

    /// `@convention(c)` trampoline for `GtkSettings::notify::…`. The handler
    /// is process-wide and carries no user data; it fans out through
    /// `GTKAppearance`.
    let appearanceNotifyTrampoline: @convention(c) (
        gpointer?,
        gpointer?,
        gpointer?
    ) -> Void = { _, _, _ in
        MainActor.assumeIsolated { GTKAppearance.preferenceChanged() }
    }
#endif
