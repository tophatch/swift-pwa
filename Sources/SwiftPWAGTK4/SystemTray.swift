#if os(Linux)
    import CStatusNotifierShim
    import Foundation
    import SwiftPWACore

    /// `Tray` for the GTK4 backend, backed by a hand-rolled
    /// StatusNotifierItem + `com.canonical.dbusmenu` implementation over
    /// GDBus (`CStatusNotifierShim`). GTK4 removed `GtkStatusIcon`, and
    /// `libayatana-appindicator3` (which the GTK3 backend uses) links
    /// GTK3 — a process can't link both GTK versions. Rather than depend
    /// on the not-yet-packaged `libayatana-appindicator-gtk4`, this
    /// speaks the two freedesktop tray D-Bus protocols directly, with no
    /// external tray dependency (GDBus + GdkPixbuf are already linked).
    ///
    /// The whole state machine — the D-Bus objects, the menu, the signal
    /// emission — lives in the C shim; Swift just holds the opaque handle
    /// and forwards user calls. This mirrors the GTK3 `SystemTray`
    /// exactly, differing only in which shim it imports.
    ///
    /// SNI is what GNOME (with the AppIndicator extension), Plasma, Sway,
    /// Hyprland, XFCE, MATE, Cinnamon all consume. Where no panel
    /// implements a StatusNotifierHost the item simply isn't displayed —
    /// the shim owns its bus name, registers when a watcher appears, and
    /// never crashes.
    ///
    /// **`.click` events are never emitted on Linux.** SNI gives the
    /// desktop panel ownership of click semantics — apps only see menu
    /// activations, same as the GTK3 backend.
    @MainActor
    public final class SystemTray: Tray {
        // The clang importer sees the full struct in the inline shim
        // header, so `swiftpwa_tray *` imports as a typed pointer.
        private var trayPtr: UnsafeMutablePointer<swiftpwa_tray>?
        private var continuations: [UUID: AsyncStream<TrayEvent>.Continuation] = [:]

        /// The Swift instance is retained on construction and the raw
        /// pointer handed to the shim as the trampoline's user data. The
        /// `passRetained` is intentionally matched by no `release` —
        /// `SystemTray` lives for the app lifetime, so the leaked retain
        /// is the design rather than a bug (and it keeps `deinit` off the
        /// non-Sendable-property path Swift 6 flags).
        public init() {
            let opaque = Unmanaged.passRetained(self).toOpaque()
            trayPtr = swiftpwa_tray_new(trayEventTrampoline, opaque)
        }

        public func setIcon(path: String, template _: Bool) {
            guard let p = trayPtr else { return }
            // SNI ships raw ARGB pixels, so `template` (macOS auto-tint)
            // is a no-op here.
            path.withCString { swiftpwa_tray_set_icon_path(p, $0) }
        }

        /// The panel's likely polarity, from the XDG portal's colour-scheme
        /// preference — see `swiftpwa_prefers_light_art` for the mapping and why
        /// it isn't symmetric.
        ///
        /// Never `nil`: the protocol's default means "this platform doesn't
        /// adapt", which is true of Apple (AppKit tints template art) and not of
        /// Linux, where nothing tints anything and something has to be chosen.
        public var prefersLightArt: Bool? {
            swiftpwa_prefers_light_art() == 1
        }

        public func setTooltip(_ text: String) {
            guard let p = trayPtr else { return }
            text.withCString { swiftpwa_tray_set_tooltip(p, $0) }
        }

        public func setMenu(_ menu: TrayMenu) {
            guard let p = trayPtr else { return }
            swiftpwa_tray_menu_begin(p)
            for item in menu.items {
                if item.separator {
                    swiftpwa_tray_menu_append_separator(p)
                } else {
                    item.id.withCString { idC in
                        item.label.withCString { labelC in
                            swiftpwa_tray_menu_append_item(p, idC, labelC, item.enabled ? 1 : 0)
                        }
                    }
                }
            }
            swiftpwa_tray_menu_commit(p)
        }

        public func setVisible(_ visible: Bool) {
            guard let p = trayPtr else { return }
            swiftpwa_tray_set_visible(p, visible ? 1 : 0)
        }

        public func eventStream() -> AsyncStream<TrayEvent> {
            let key = UUID()
            return AsyncStream { continuation in
                self.continuations[key] = continuation
                continuation.onTermination = { @Sendable _ in
                    Task { @MainActor in self.continuations.removeValue(forKey: key) }
                }
            }
        }

        fileprivate func _emit(_ event: TrayEvent) {
            for c in continuations.values { c.yield(event) }
        }

        /// The session-bus name this tray registered as. Used by the
        /// integration test to address the item; not part of the public
        /// cross-platform `Tray` surface.
        var registeredBusName: String {
            trayPtr.map { String(cString: swiftpwa_tray_bus_name($0)) } ?? ""
        }
    }

    /// `@convention(c)` callback for `swiftpwa_tray_*`. Fires on the
    /// thread pumping the GLib main context (the GTK4 main thread), so we
    /// hop into MainActor-isolated code via `assumeIsolated`.
    let trayEventTrampoline: @convention(c) (
        Int32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?
    ) -> Void = { kind, idPtr, userData in
        guard let userData else { return }
        let userDataRaw = UInt(bitPattern: userData)
        let id: String? = idPtr.map { String(cString: $0) }
        MainActor.assumeIsolated {
            guard let opaque = UnsafeMutableRawPointer(bitPattern: userDataRaw) else { return }
            let tray = Unmanaged<SystemTray>.fromOpaque(opaque).takeUnretainedValue()
            switch kind {
            case 0: tray._emit(.click)
            case 1: tray._emit(.menuItemClicked(id: id ?? ""))
            default: break
            }
        }
    }
#endif
