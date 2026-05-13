#if os(Android)
    import CSwiftPWAAndroidJNI
    import Dispatch
    import Foundation
    import SwiftPWACore

    /// Android-side `AppContext`.
    ///
    /// Singleton because there is one `Activity` per process and the
    /// JNI bridge is process-wide. The Kotlin `SwiftPWABridge` is
    /// attached once at `Activity.onCreate` and detached at
    /// `Activity.onDestroy`; the singleton tracks the resulting
    /// window state and routes inbound JSON frames to it.
    /// The cross-platform `AppContext` protocol is `@MainActor`, but
    /// on Android we can't actually hop to a Swift-runtime MainActor
    /// (libdispatch's main queue isn't drained by anyone, so
    /// `MainActor.assumeIsolated` traps from non-main threads). The
    /// backend therefore conforms `nonisolated` and protects shared
    /// state with the single-threaded access pattern: configure runs
    /// once on the JNI worker thread before that thread blocks on
    /// the run semaphore, and writes after that point come from a
    /// single thread (the binder pool routing through `routeInbound`
    /// / `completeRun`, both already nonisolated). `@unchecked
    /// Sendable` is the price paid for this.
    public final nonisolated class AndroidAppContext: AppContext, @unchecked Sendable {
        public static let shared = AndroidAppContext()

        public let registry = CommandRegistry()
        public private(set) nonisolated(unsafe) var windows: [WindowID: any Window] = [:]
        // `pendingExitCode` is read by the runtime worker thread
        // (in `AndroidAppRuntime.run`) right after `runSemaphore`
        // is signalled, and written by `quit` (MainActor) and
        // `completeRun` (binder thread via JNI). The semaphore acts
        // as the happens-before edge: any thread that signals it
        // has already written `pendingExitCode`. `nonisolated(unsafe)`
        // here so the binder-thread JNI quit handler can write it
        // without trying (and trapping) to hop to MainActor — Android's
        // `MainActor.assumeIsolated` is strictly enforced via
        // libdispatch's `dispatch_assert_queue(main)` and would crash
        // the binder thread.
        public private(set) nonisolated(unsafe) var pendingExitCode: Int32?
        private nonisolated(unsafe) var installedPlugins: Set<String> = []

        /// Most recently created window. The first `createWindow`
        /// call wires the primary Activity's WebView; later calls
        /// JNI-spawn a secondary Activity. Inbound JS frames route
        /// to whichever AndroidWindow this points at.
        ///
        /// `nonisolated(unsafe)`: written from `createWindow`
        /// (MainActor, runs once during `configure`) and read from
        /// `routeInbound` (binder threads, after configure has
        /// returned). The synchronisation is loose — a frame that
        /// arrives before configure completes is silently dropped,
        /// which is the right behaviour for a transient pre-window
        /// state. After configure returns the value is stable.
        nonisolated(unsafe) var activeWindow: AndroidWindow?

        /// Released by `completeRun(exitCode:)` to unblock
        /// `AndroidAppRuntime.run`'s wait.
        nonisolated let runSemaphore = DispatchSemaphore(value: 0)

        private init() {
            use(WindowPlugin())
            use(PlatformInfoPlugin())
            // Auto-register `ClipboardPlugin` so apps don't have to —
            // every other backend's `AppContext` does the same. Apps
            // can override with their own `ctx.use(ClipboardPlugin(...))`
            // since `use` short-circuits on already-installed plugins
            // by name.
            use(ClipboardPlugin(SystemClipboard()))

            // Route `content://` URIs from SAF dialog results through
            // the Kotlin `ContentResolver` so apps can hand a SAF-
            // picker URI straight to `fs.readBinary` / `writeBinary` /
            // `metadata` without special-casing. The resolver slot is
            // process-wide; doing this here means `FsPlugin(SystemFs())`
            // on Android transparently handles content URIs without
            // any app-side setup.
            SystemFs.setContentResolver(AndroidContentResolver())
        }

        @discardableResult
        public func createWindow(_ config: WindowConfig) throws -> any Window {
            // First call binds to the primary Activity that's already
            // running (the JNI entry-point Activity). Subsequent calls
            // JNI-launch a fresh MainActivity instance carrying the
            // configured content as an intent extra — the secondary
            // Activity then becomes the foreground bridge until the
            // user navigates back. The `AndroidWindow` returned in
            // the secondary case is `.secondary`: it carries a stub
            // `WebView` adapter that doesn't itself reach the spawned
            // Activity's WebView, since the C shim's bridge ref is
            // single-slot. Cross-Activity Swift→WebView calls are
            // out of scope for v0.5.x; the spawned Activity owns its
            // own JS runtime. Documented in `docs/android-setup.md`.
            let isPrimary = windows.isEmpty
            let win = AndroidWindow(config: config, role: isPrimary ? .primary : .secondary)
            windows[win.id] = win
            activeWindow = win
            if isPrimary {
                win.webView.load(config.content)
            } else {
                spawnSecondaryActivity(config: config)
            }
            return win
        }

        /// Encode `config` as the JSON the Kotlin secondary-Activity
        /// path expects (`{"url": String, "title": String?}`) and
        /// JNI-call into the bridge to do the `startActivity`. The
        /// URL is resolved through the same `AndroidWebViewAdapter`
        /// resolver the primary uses so `.bundled` / `.remote` both
        /// reach the right place.
        private func spawnSecondaryActivity(config: WindowConfig) {
            let url = AndroidWebViewAdapter.resolveURL(for: config.content)
            // Build the JSON by hand — two fields, both strings, no
            // escaping wrinkles beyond standard JSONEncoder coverage.
            struct ConfigJSON: Encodable {
                let url: String
                let title: String?
            }
            let payload = ConfigJSON(url: url, title: config.title.isEmpty ? nil : config.title)
            guard let data = try? JSONEncoder().encode(payload),
                  let json = String(data: data, encoding: .utf8)
            else {
                swiftpwa_android_log("createWindow: failed to encode secondary config JSON")
                return
            }
            json.withCString { swiftpwa_android_spawn_window($0) }
        }

        public func use(_ plugin: any Plugin) {
            let name = type(of: plugin).pluginName
            guard installedPlugins.insert(name).inserted else { return }
            // `Plugin.register` is `@MainActor` per the protocol,
            // but we're nonisolated on Android. Cast the call to a
            // matching non-isolated function pointer and invoke
            // directly — the registry is a thread-safe class with
            // its own NSLock, so the @MainActor annotation is a
            // type-system formality here. Avoids `assumeIsolated`,
            // which would trap from this thread (libdispatch's main
            // queue assertion).
            typealias UnisolatedRegister = @Sendable (
                any Plugin, CommandRegistry, any AppContext
            ) -> Void
            let isolated: @MainActor @Sendable (
                any Plugin, CommandRegistry, any AppContext
            ) -> Void = { p, r, a in
                p.register(into: r, app: a)
            }
            let unisolated = unsafeBitCast(isolated, to: UnisolatedRegister.self)
            unisolated(plugin, registry, self)
        }

        public func window(_ id: WindowID) -> (any Window)? { windows[id] }

        public func quit(exitCode: Int32) {
            pendingExitCode = exitCode
            // Tell the JNI side first so Kotlin can finish() the
            // Activity, then unblock `run`. Order matters: if we
            // signaled the semaphore first, the worker would
            // `exit()` before the Activity got a chance to clean
            // up its UI state.
            swiftpwa_android_dispatch_quit(exitCode)
        }

        /// Called from the JNI quit trampoline (binder thread) or
        /// from `quit(exitCode:)` (MainActor). Sets the exit code if
        /// not already set, then signals the run semaphore so
        /// `AndroidAppRuntime.run` unblocks.
        ///
        /// Direct write to `pendingExitCode` is safe because the
        /// property is `nonisolated(unsafe)` — see its declaration
        /// for the synchronisation argument. `MainActor.assumeIsolated`
        /// is *not* an option on Android: from a binder thread the
        /// libdispatch main-queue assertion fires and crashes the
        /// process with `SIGTRAP` in `_dispatch_assert_queue_fail`.
        nonisolated func completeRun(exitCode: Int32) {
            if pendingExitCode == nil { pendingExitCode = exitCode }
            runSemaphore.signal()
        }

        /// Inbound JSON frame — JNI hands us the string after the
        /// `addJavascriptInterface` callback fires on a binder
        /// thread. Forward to the active window's adapter without
        /// hopping to MainActor: `AsyncStream.Continuation.yield`
        /// is documented thread-safe, and the `activeWindow`
        /// reference is stable after `configure` returns.
        nonisolated func routeInbound(jsonString: String) {
            activeWindow?.adapter._ingest(jsonString: jsonString)
        }
    }
#endif
