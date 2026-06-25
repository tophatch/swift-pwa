#if os(Linux)
    import CGtk3Shim
    import Foundation
    import SwiftPWACore

    @MainActor
    public final class GTKAppContext: AppContext {
        public static let shared = GTKAppContext()

        public let registry = CommandRegistry()
        public let assetProvider = AssetProvider()
        public private(set) var windows: [WindowID: any Window] = [:]
        public var pendingExitCode: Int32?
        private var installedPlugins: Set<String> = []

        private init() {
            use(WindowPlugin())
            use(PlatformInfoPlugin())
            use(AppPlugin())
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
            gtk_main_quit()
        }

        func windowDidClose(_ id: WindowID) {
            windows.removeValue(forKey: id)
            // Linux convention: closing the last window terminates the
            // app (unlike Mac, where the menu bar lingers). If the host
            // wants Mac-style "stay alive after last window", they can
            // create a hidden placeholder window.
            if windows.isEmpty {
                quit(exitCode: pendingExitCode ?? 0)
            }
        }
    }
#endif
