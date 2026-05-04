#if os(Linux)
    import Foundation
    import SwiftPWACore

    /// GTK4 removed `GtkStatusIcon` outright; the modern replacement is
    /// the StatusNotifierItem protocol via libayatana-appindicator,
    /// which we don't yet depend on. Until that lands, the GTK4 backend
    /// ships a no-op `SystemTray` so `TrayPlugin(SystemTray())` still
    /// works portably — the tray just isn't displayed. A one-shot
    /// warning is logged the first time anything is called.
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
            FileHandle.standardError.write(Data(msg.utf8))
        }
    }
#endif
