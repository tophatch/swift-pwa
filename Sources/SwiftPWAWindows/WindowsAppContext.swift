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
        public let assetProvider = AssetProvider(scheme: "https", host: "swift-pwa.local")
        public let events = EventBus()
        public let permissions = PermissionPolicy()
        public let externalURLs = ExternalURLPolicy()

        /// The platform pieces a plugin can pick up without the app naming a
        /// backend type (see ``AppContext/urlOpener``). Windows has no OS
        /// authorization browser, so a sign-in opens the default one and
        /// catches the redirect on loopback — which is also why loopback is
        /// what `redirect: 'auto'` picks here: a portable `.exe` can't register
        /// a URL scheme without the user running a script first.
        public let urlOpener: (any URLOpener)? = WindowsURLOpener()
        /// Stored to satisfy ``AppContext``; this backend never reads it.
        /// macOS is the only platform where an app outlives its windows —
        /// see ``LastWindowClosedPolicy``.
        public var lastWindowClosed: LastWindowClosedPolicy = .reopen
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
            use(SystemPlugin(urlOpener: WindowsURLOpener()))
            use(AppPlugin())
            use(PermissionsPlugin())
            use(EventsPlugin())
            // Backs the `navigator.audioSession` polyfill. Records the type and
            // reports it; it drives no platform mechanism, because this one has
            // none an embedder can reach — the playing stream belongs to the
            // webview's own process, and session policy here is set per stream
            // by its creator. See `RecordingAudioSession` for the measurements.
            use(AudioSessionPlugin(RecordingAudioSession()))
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
            let effective = WindowStateStore.shared.restore(config)
            let win = try Win32Window(config: effective, app: self, environment: env)
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

        /// Quit once every window's page has finished and the app's
        /// `beforeClose` handlers have run, within ``CloseBudget/quit`` (#281).
        public func quit(exitCode: Int32) {
            pendingExitCode = exitCode
            guard !quitting else { return }
            quitting = true
            Task { @MainActor in
                await Closing.beforeQuit(self, reason: .quit)
                PostQuitMessage(pendingExitCode ?? exitCode)
            }
        }

        private var quitting = false

        /// The session is ending (logoff, restart, shutdown). Windows ends the
        /// process as soon as WM_ENDSESSION returns, so the whole quit has to
        /// happen inside it: pump the thread here — messages and the main
        /// queue both, as the main loop does — until it's done, or until just
        /// under the five seconds Windows allows before it calls the app hung.
        func endSession() {
            guard !quitting else { return }
            quitting = true
            final class Progress { var finished = false }
            let progress = Progress()
            Task { @MainActor in
                await Closing.beforeQuit(self, reason: .system, budget: .milliseconds(4000))
                progress.finished = true
            }
            let giveUpAt = GetTickCount64() + 4500
            var handles: [HANDLE?] = PlatformMainQueue.handle.map { [$0] } ?? []
            var msg = MSG()
            while !progress.finished, GetTickCount64() < giveUpAt {
                let signalled = handles.withUnsafeMutableBufferPointer { buffer in
                    MsgWaitForMultipleObjectsEx(
                        DWORD(buffer.count), buffer.baseAddress, 50, DWORD(QS_ALLINPUT), DWORD(MWMO_INPUTAVAILABLE)
                    )
                }
                if !handles.isEmpty, signalled == WAIT_OBJECT_0 {
                    PlatformMainQueue.drain()
                    continue
                }
                while PeekMessageW(&msg, nil, 0, 0, UINT(PM_REMOVE)) {
                    if msg.message == UINT(WM_QUIT) { continue }
                    TranslateMessage(&msg)
                    DispatchMessageW(&msg)
                }
            }
        }

        func windowDidClose(_ id: WindowID) {
            windows.removeValue(forKey: id)
            // Windows convention matches Linux: closing the last
            // window terminates the app. Apps that want Mac-style
            // "live in the tray after last window" can keep a hidden
            // owner window alive themselves.
            if windows.isEmpty {
                // Flush any debounced window geometry before the message loop
                // exits — the async `.didClose` handler may not get to run.
                WindowStateStore.shared.flushNow()
                quit(exitCode: pendingExitCode ?? 0)
            }
        }
    }
#endif
