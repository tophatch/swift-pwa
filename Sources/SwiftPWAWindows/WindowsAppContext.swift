#if os(Windows)
    import CWebView2Shim
    import Foundation
    import SwiftPWACore
    import WinSDK

    /// Windows-side `AppContext`.
    ///
    /// Singleton because the WebView2 environment is process-wide:
    /// the runtime spawns one browser process per user-data folder,
    /// and we keep that handle on the context so every `Win32Window`
    /// can attach a controller without re-creating it.
    @MainActor
    public final class WindowsAppContext: AppContext {
        public static let shared = WindowsAppContext()

        public let registry = CommandRegistry()
        public private(set) var windows: [WindowID: any Window] = [:]
        public var pendingExitCode: Int32?
        private var installedPlugins: Set<String> = []

        /// Opaque WebView2 environment handle. Filled in by the
        /// runtime's `envReadyTrampoline` once the async creation
        /// completes; observed via `environmentReady` during startup.
        nonisolated(unsafe) var environment: OpaquePointer?
        nonisolated(unsafe) var environmentReady = false

        private init() {
            use(WindowPlugin())
            use(PlatformInfoPlugin())
            use(ClipboardPlugin(SystemClipboard()))
        }

        func installEnvironment(_ env: OpaquePointer?) {
            environment = env
            environmentReady = true
        }

        @discardableResult
        public func createWindow(_ config: WindowConfig) throws -> any Window {
            guard let env = environment else {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "WebView2 environment not ready"
                )
            }
            let win = try Win32Window(config: config, app: self, environment: env)
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
            PostQuitMessage(exitCode)
        }

        func windowDidClose(_ id: WindowID) {
            windows.removeValue(forKey: id)
            // Windows convention matches Linux: closing the last
            // window terminates the app. Apps that want Mac-style
            // "live in the tray after last window" can keep a hidden
            // owner window alive themselves.
            if windows.isEmpty {
                quit(exitCode: pendingExitCode ?? 0)
            }
        }
    }
#endif
