#if os(Linux)
    import CAyatanaAppIndicator3Shim
    import CGtk3Shim
    import Foundation
    import SwiftPWACore

    /// `Tray` backed by `libayatana-appindicator3` (StatusNotifierItem
    /// over D-Bus) on the GTK3 backend. The whole state machine —
    /// `AppIndicator` instance, currently-attached menu, signal
    /// trampolines — lives in the AppIndicator C shim; Swift just
    /// holds the opaque handle and forwards user calls. The shim
    /// invokes `trayEventTrampoline` on the GTK main thread when a
    /// menu item is activated.
    ///
    /// SNI is what GNOME (with the AppIndicator extension), Plasma,
    /// Sway, Hyprland, XFCE, MATE, Cinnamon all consume; on legacy
    /// Xembed-only desktops the AppIndicator library falls back to
    /// drawing a `GtkStatusIcon` itself, so this works everywhere the
    /// previous `GtkStatusIcon`-based code did, plus modern Wayland
    /// targets the old code couldn't reach.
    ///
    /// **`.click` events are never emitted on Linux.** SNI gives the
    /// desktop panel ownership of click semantics — the host decides
    /// what happens (typically: open the menu). Apps only see menu
    /// activations. The GTK4 backend's `SystemTray` stays a no-op
    /// stub because `libayatana-appindicator3` is GTK3-only and a
    /// process can't link both GTK versions at once.
    @MainActor
    public final class SystemTray: Tray {
        // Swift's clang importer sees the full struct definition in
        // the inline shim header, so `swiftpwa_tray *` imports as a
        // typed `UnsafeMutablePointer<swiftpwa_tray>`, not the
        // `OpaquePointer` you'd get for a forward-declared type.
        private var trayPtr: UnsafeMutablePointer<swiftpwa_tray>?
        private var continuations: [UUID: AsyncStream<TrayEvent>.Continuation] = [:]

        /// The Swift instance is retained on construction and the raw
        /// pointer is handed to the C shim as the trampoline's user
        /// data, so the trampoline can resolve back to `self` via
        /// `Unmanaged.fromOpaque`. The `passRetained` is intentionally
        /// matched by no `release` anywhere — `SystemTray` is meant
        /// to live for the app lifetime, so the leaked retain is the
        /// design rather than a bug. (And because `deinit` therefore
        /// cannot be reached, attempting to call `swiftpwa_tray_free`
        /// from one runs into Swift 6's "non-Sendable property in
        /// nonisolated deinit" rule for nothing.)
        public init() {
            let opaque = Unmanaged.passRetained(self).toOpaque()
            trayPtr = swiftpwa_tray_new(trayEventTrampoline, opaque)
        }

        public func setIcon(path: String, template _: Bool) {
            guard let p = trayPtr else { return }
            // GTK doesn't auto-tint icons, so `template` is a no-op here.
            path.withCString { swiftpwa_tray_set_icon_path(p, $0) }
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

        /// Parity with the GTK4 backend's test accessor. The GTK3 tray
        /// goes through `libayatana-appindicator`, which owns and hides
        /// the SNI bus name, so there's nothing to report here.
        var registeredBusName: String {
            ""
        }
    }

    /// `@convention(c)` callback for `swiftpwa_tray_*`. Always fires on
    /// the GTK main thread (signals are dispatched there), so we hop
    /// into MainActor-isolated code via `assumeIsolated`.
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
