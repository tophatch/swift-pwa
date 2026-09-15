#if os(Linux)
    import CGtk3Shim
    import Foundation
    import SwiftPWACore

    @MainActor
    public final class GTKAppContext: AppContext {
        public static let shared = GTKAppContext()

        public let registry = CommandRegistry()
        public let assetProvider = AssetProvider()
        public let events = EventBus()
        public let permissions = PermissionPolicy()
        public let externalURLs = ExternalURLPolicy()
        /// Stored to satisfy ``AppContext``; this backend never reads it.
        /// macOS is the only platform where an app outlives its windows —
        /// see ``LastWindowClosedPolicy``.
        public var lastWindowClosed: LastWindowClosedPolicy = .reopen
        public private(set) var windows: [WindowID: any Window] = [:]
        public var pendingExitCode: Int32?
        private var installedPlugins: Set<String> = []

        private init() {
            use(WindowPlugin())
            use(PlatformInfoPlugin())
            use(SystemPlugin(urlOpener: GTKURLOpener()))
            use(AppPlugin())
            use(EventsPlugin())
            // Backs the `navigator.audioSession` polyfill. Records the type and
            // reports it; it drives no platform mechanism, because this one has
            // none an embedder can reach — the playing stream belongs to the
            // webview's own process, and session policy here is set per stream
            // by its creator. See `RecordingAudioSession` for the measurements.
            use(AudioSessionPlugin(RecordingAudioSession()))
            use(ClipboardPlugin(SystemClipboard()))
        }

        @discardableResult
        public func createWindow(_ config: WindowConfig) throws -> any Window {
            let effective = WindowStateStore.shared.restore(config)
            let win = try GTKWindow(config: effective, app: self)
            WindowStateStore.shared.track(win, config: effective)
            windows[win.id] = win
            return win
        }

        public func use(_ plugin: any Plugin) {
            let name = type(of: plugin).pluginName
            guard installedPlugins.insert(name).inserted else { return }
            plugin.register(into: registry, app: self)
        }

        public func window(_ id: WindowID) -> (any Window)? { windows[id] }

        public func quit(exitCode: Int32) {
            pendingExitCode = exitCode
            // There is no loop to quit when a GUI-gated test closes a window:
            // `initGTKForTesting` initializes GTK without entering `gtk_main`,
            // and quitting anyway is a GTK CRITICAL rather than a no-op.
            guard gtk_main_level() > 0 else { return }
            gtk_main_quit()
        }

        func windowDidClose(_ id: WindowID) {
            windows.removeValue(forKey: id)
            // Linux convention: closing the last window terminates the
            // app (unlike Mac, where the menu bar lingers). If the host
            // wants Mac-style "stay alive after last window", they can
            // create a hidden placeholder window.
            if windows.isEmpty {
                // Flush any debounced window geometry before the loop tears
                // down — the async `.didClose` handler may not get to run.
                WindowStateStore.shared.flushNow()
                quit(exitCode: pendingExitCode ?? 0)
            }
        }
    }
#endif
