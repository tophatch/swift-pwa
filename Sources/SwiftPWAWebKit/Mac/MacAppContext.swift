#if os(macOS)
    import AppKit
    import Foundation
    import SwiftPWACore

    @MainActor
    public final class MacAppContext: AppContext {
        public let registry = CommandRegistry()
        public let assetProvider = AssetProvider()
        public let events = EventBus()
        public let permissions = PermissionPolicy()
        public let externalURLs = ExternalURLPolicy()

        /// The platform pieces a plugin can pick up without the app naming a
        /// backend type (see ``AppContext/urlOpener``).
        public let urlOpener: (any URLOpener)? = AppleURLOpener()
        public let authorizationSession: (any AuthorizationSessionPresenter)? = SystemAuthorizationSession()
        public private(set) var windows: [WindowID: any Window] = [:]
        public var pendingExitCode: Int32?
        public var lastWindowClosed: LastWindowClosedPolicy = .reopen
        private var installedPlugins: Set<String> = []
        /// The config the most recent window was created from, kept so
        /// ``LastWindowClosedPolicy/reopen`` can build that window again. The
        /// runtime can't ask the app to make another one — the app creates its
        /// window inside `configure`, which has long since returned by the time
        /// a user closes it — so the description of the window is what has to
        /// survive. Post-restore (`WindowStateStore`), so a reopened window
        /// lands where the closed one was rather than back at its launch size.
        private var lastWindowConfig: WindowConfig?

        public init() {
            // Install the built-in plugins eagerly so window.* and
            // clipboard.* JS commands work without the user having to
            // do it manually.
            use(WindowPlugin())
            use(PlatformInfoPlugin())
            use(SystemPlugin(urlOpener: AppleURLOpener()))
            use(AppPlugin())
            use(PermissionsPlugin())
            use(EventsPlugin())
            use(ClipboardPlugin(SystemClipboard()))
        }

        @discardableResult
        public func createWindow(_ config: WindowConfig) throws -> any Window {
            let effective = WindowStateStore.shared.restore(config)
            let win = try MacWindow(config: effective, app: self)
            WindowStateStore.shared.track(win, config: effective)
            windows[win.id] = win
            lastWindowConfig = effective
            return win
        }

        /// Rebuild the last window. Called when the app is activated with no
        /// windows open under ``LastWindowClosedPolicy/reopen`` — the Dock-click
        /// path a Mac user expects. Returns whether a window now exists, so the
        /// delegate can tell AppKit whether it still needs to do anything.
        @discardableResult
        func reopenLastWindow() -> Bool {
            guard windows.isEmpty, let config = lastWindowConfig else { return !windows.isEmpty }
            do {
                try createWindow(config)
                return true
            } catch {
                // A window the app opened once can still fail to reopen (its
                // web root moved, say). Say so rather than leaving a Dock click
                // looking like it did nothing.
                FileHandle.standardError.writeQuietly(
                    Data("swift-pwa: couldn't reopen the window: \(error)\n".utf8)
                )
                return false
            }
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
            // `.reopen` / `.keepRunning` both leave the process running, which
            // is macOS's own convention and what this app has always done. The
            // difference only shows on the next activation; see
            // `reopenLastWindow`.
            guard windows.isEmpty, lastWindowClosed == .quit else { return }
            // Geometry is written on a debounce, and the run loop is about to
            // stop — flush it or the size the user just left is lost.
            WindowStateStore.shared.flushNow()
            quit(exitCode: pendingExitCode ?? 0)
        }
    }
#endif
