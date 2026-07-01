#if os(Linux)
    import CGtk4Shim
    import Foundation
    import SwiftPWACore

    @MainActor
    public final class GTKAppContext: AppContext {
        public static let shared = GTKAppContext()

        public let registry = CommandRegistry()
        public let assetProvider = AssetProvider()
        public let events = EventBus()
        public private(set) var windows: [WindowID: any Window] = [:]
        public var pendingExitCode: Int32?
        private var installedPlugins: Set<String> = []

        /// The owned `GMainLoop*` driven by `GTKAppRuntime.run`. GTK4
        /// dropped `gtk_main()` / `gtk_main_quit()`, so we manage the
        /// loop ourselves and keep a handle so `quit()` can stop it.
        private var mainLoop: OpaquePointer?

        private init() {
            use(WindowPlugin())
            use(PlatformInfoPlugin())
            use(AppPlugin())
            use(EventsPlugin())
            use(ClipboardPlugin(SystemClipboard()))
        }

        @discardableResult
        public func createWindow(_ config: WindowConfig) throws -> any Window {
            let win = try GTKWindow(config: config, app: self)
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
            if let loop = mainLoop { g_main_loop_quit(loop) }
        }

        func windowDidClose(_ id: WindowID) {
            windows.removeValue(forKey: id)
            // Linux convention: closing the last window terminates the
            // app (unlike Mac, where the menu bar lingers).
            if windows.isEmpty {
                quit(exitCode: pendingExitCode ?? 0)
            }
        }

        // MARK: - Lifecycle hooks called by GTKAppRuntime

        func installMainLoop() {
            mainLoop = g_main_loop_new(nil, gboolean(0))
        }

        func runMainLoop() {
            guard let loop = mainLoop else { return }
            g_main_loop_run(loop)
            g_main_loop_unref(loop)
            mainLoop = nil
        }
    }
#endif
