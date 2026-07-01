#if os(macOS)
    import AppKit
    import Foundation
    import SwiftPWACore

    @MainActor
    public final class MacAppContext: AppContext {
        public let registry = CommandRegistry()
        public let assetProvider = AssetProvider()
        public let events = EventBus()
        public private(set) var windows: [WindowID: any Window] = [:]
        public var pendingExitCode: Int32?
        private var installedPlugins: Set<String> = []

        public init() {
            // Install the built-in plugins eagerly so window.* and
            // clipboard.* JS commands work without the user having to
            // do it manually.
            use(WindowPlugin())
            use(PlatformInfoPlugin())
            use(AppPlugin())
            use(EventsPlugin())
            use(ClipboardPlugin(SystemClipboard()))
        }

        @discardableResult
        public func createWindow(_ config: WindowConfig) throws -> any Window {
            let win = try MacWindow(config: config, app: self)
            windows[win.id] = win
            return win
        }

        public func use(_ plugin: any Plugin) {
            let name = type(of: plugin).pluginName
            guard installedPlugins.insert(name).inserted else { return }
            plugin.register(into: registry, app: self)
        }

        public func window(_ id: WindowID) -> (any Window)? {
            windows[id]
        }

        public func quit(exitCode: Int32) {
            pendingExitCode = exitCode
            NSApp.terminate(nil)
        }

        /// Called by `MacWindow` when its NSWindow finishes closing.
        func windowDidClose(_ id: WindowID) {
            windows.removeValue(forKey: id)
        }
    }
#endif
