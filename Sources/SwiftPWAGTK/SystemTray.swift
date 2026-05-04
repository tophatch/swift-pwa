#if os(Linux)
    import CGtk3Shim
    import Foundation
    import SwiftPWACore

    /// `Tray` backed by `GtkStatusIcon` on the GTK3 backend. The whole
    /// state machine (status icon, currently-attached menu, signal
    /// trampolines) lives in the C shim — Swift just holds an opaque
    /// `swiftpwa_tray *` and forwards user calls. The shim invokes
    /// `trayEventTrampoline` on the GTK main thread when the icon is
    /// clicked or a menu item is activated.
    ///
    /// `GtkStatusIcon` is deprecated upstream but is still the simplest
    /// surface that works on most Linux desktops without dragging in
    /// libayatana-appindicator. AppIndicator support is on the roadmap;
    /// until then the GTK4 backend ships a no-op `SystemTray` since
    /// `GtkStatusIcon` was removed entirely in GTK4.
    @MainActor
    public final class SystemTray: Tray {
        private var trayPtr: OpaquePointer?
        private var continuations: [UUID: AsyncStream<TrayEvent>.Continuation] = [:]

        /// The Swift instance is retained on construction and the raw
        /// pointer is handed to the C shim as the trampoline's user
        /// data, so the trampoline can resolve back to `self` via
        /// `Unmanaged.fromOpaque`.
        public init() {
            let opaque = Unmanaged.passRetained(self).toOpaque()
            trayPtr = swiftpwa_tray_new(trayEventTrampoline, opaque)
        }

        deinit {
            // SystemTray is intended to live for the app lifetime; if
            // it does get torn down, free the GTK side. We don't release
            // the retained `self` here — the trampoline is the only
            // holder, and we're already in `deinit` so there's nothing
            // to release back to.
            if let p = trayPtr { swiftpwa_tray_free(p) }
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
