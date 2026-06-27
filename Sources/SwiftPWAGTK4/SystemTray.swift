#if os(Linux)
    import Foundation
    import SwiftPWACore

    /// GTK4 removed `GtkStatusIcon`; the modern path on Linux is the
    /// StatusNotifierItem protocol via libayatana-appindicator, which
    /// the GTK3 backend uses. We can't reuse it here because
    /// `libayatana-appindicator3` is built against GTK3 and a process
    /// can't link both GTK3 and GTK4 — and `libayatana-appindicator-gtk4`
    /// isn't yet broadly packaged on Ubuntu / Fedora. Until that
    /// changes, the GTK4 backend ships a no-op `SystemTray` so
    /// `TrayPlugin(SystemTray())` still compiles and runs portably —
    /// the tray just isn't displayed. A one-shot warning is logged
    /// the first time anything is called.
    @MainActor
    public final class SystemTray: Tray {
        private var warned = false

        public init() {}

        public func setIcon(path _: String, template _: Bool) { warnOnce() }
        public func setTooltip(_: String) { warnOnce() }
        public func setMenu(_: TrayMenu) { warnOnce() }
        public func setVisible(_: Bool) { warnOnce() }

        public func eventStream() -> AsyncStream<TrayEvent> {
            AsyncStream { $0.finish() }
        }

        private func warnOnce() {
            guard !warned else { return }
            warned = true
            let msg = "swift-pwa: TrayPlugin is a no-op on the GTK4 backend"
                + " — `GtkStatusIcon` is gone and AppIndicator support is not yet wired in.\n"
            FileHandle.standardError.writeQuietly(Data(msg.utf8))
        }
    }
#endif
