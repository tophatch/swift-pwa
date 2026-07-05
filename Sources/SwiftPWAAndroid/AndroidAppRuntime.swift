#if os(Android)
    import CSwiftPWAAndroidJNI
    import Dispatch
    import Foundation
    import SwiftPWACore

    /// Android-side runtime.
    ///
    /// **Important:** unlike the Apple / GTK / Windows backends, the
    /// runtime here does *not* drive a UI event loop. Android's UI
    /// thread is owned by the JVM (the `Activity` and its `Looper`).
    /// Our Swift code compiles to a shared object that the Kotlin
    /// `MainActivity` loads via `System.loadLibrary` and calls into
    /// from a dedicated worker thread.
    ///
    /// The flow is:
    ///
    ///   1. The Activity's `onCreate` constructs a `SwiftPWABridge`
    ///      instance backed by the WebView, then calls
    ///      `SwiftPWABridge.nativeAttach(bridge)` (JNI -> us). The
    ///      shim caches a global ref + the method IDs.
    ///   2. The Activity then spawns a worker `Thread` that calls
    ///      into our exported `swiftpwa_android_main` (the symbol the
    ///      user provides via `@_cdecl`, wrapping their `configure`
    ///      closure — see `docs/android-setup.md`). That entry calls
    ///      `AndroidAppRuntime().run(configure)`.
    ///   3. `run` registers handlers (inbound, quit, main-thread
    ///      runner), runs the user's `configure` closure
    ///      synchronously on the worker thread, then **blocks** on a
    ///      semaphore until `quit(exitCode:)` is called.
    ///   4. `quit(exitCode:)` releases the semaphore. `run` returns
    ///      to its caller (which on Android is the worker thread's
    ///      JNI bootstrap), which then signals back to Kotlin to
    ///      tear the Activity down.
    ///
    /// `MainThread.run` is wired to a JNI hop to
    /// `Handler(Looper.getMainLooper()).post(...)`, mirroring the
    /// shape of the Windows dispatcher window and the GTK
    /// `g_idle_add` hook.
    public final class AndroidAppRuntime: AppRuntime, @unchecked Sendable {
        public init() {}

        /// The protocol declares `run` as `@MainActor`, but on Android
        /// there is no Swift-runtime-pumped MainActor — the OS UI
        /// thread belongs to the JVM (the Activity's Looper), and
        /// libdispatch's main queue isn't drained by anyone. Calling
        /// `MainActor.assumeIsolated` from a worker thread traps via
        /// `dispatch_assert_queue_fail`. Adopting the protocol with
        /// `nonisolated` here lets the JNI `@_cdecl` entry call
        /// `runtime.run(configure)` synchronously without any actor
        /// hops; UI-bound work is routed to the Android UI thread
        /// explicitly through `MainThread.run` (which JNI-posts to
        /// `Handler(Looper.getMainLooper())`).
        public nonisolated func run(
            _ configure: @escaping @MainActor @Sendable (any AppContext) throws -> Void
        ) throws -> Never {
            installMainThreadHook()

            let context = AndroidAppContext.shared

            // Inbound JSON frames: route to whichever WebView adapter
            // is currently active. There is at most one window on
            // Android (multi-window is a v0.5.x follow-up — the
            // platform-native UX is single-Activity), so we forward
            // unconditionally to the most recently created adapter.
            swiftpwa_android_set_inbound_handler({ jsonPtr, _ in
                guard let jsonPtr else { return }
                let json = String(cString: jsonPtr)
                AndroidAppContext.shared.routeInbound(jsonString: json)
            }, nil)

            // Quit handler: JNI calls this when the Activity tears
            // down (or the user invokes `context.quit(exitCode:)`).
            // Releases the run-loop semaphore so this method returns.
            swiftpwa_android_set_quit_handler({ exitCode, _ in
                AndroidAppContext.shared.completeRun(exitCode: Int32(exitCode))
            }, nil)

            // OS "Open with" / share-sheet: `MainActivity` reads the
            // launch/new intent's file URI(s) and pushes them on the
            // `app.openFile` channel; re-emit them on the event bus
            // (retained) so JS receives them via `on('app.openFile', …)`
            // even when a file *cold-launched* the app. Registered before
            // the host-event handler is installed below so the C-shim's
            // pre-handler buffer flush (of an `onCreate`-time push) finds
            // this subscriber. On Android the paths are `content://` URIs,
            // read via the `fs.*` content-URI methods.
            AndroidHostEventRouter.subscribe(channel: OpenFile.channel) { data in
                struct Payload: Decodable { let paths: [String] }
                guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
                OpenFile.emit(payload.paths, on: context.events)
            }

            // Host events: Kotlin-side asynchronous pushes that don't
            // fit the JS bridge envelope or the RPC request/response
            // shape — `BroadcastReceiver` payloads, lifecycle hooks,
            // etc. The router dispatches by `channel`; plugins
            // (currently `AndroidUpdater`) subscribe at init time.
            swiftpwa_android_set_host_event_handler({ jsonPtr, _ in
                guard let jsonPtr else { return }
                let json = String(cString: jsonPtr)
                AndroidHostEventRouter.dispatch(jsonString: json)
            }, nil)

            // The configure closure is declared `@MainActor` by the
            // protocol, but here we're already nonisolated. We invoke
            // it via `unsafeBitCast` to a same-shape non-isolated
            // function — the closure's body still type-checks as
            // MainActor at the call sites it makes (e.g.
            // `ctx.createWindow`), but at runtime there's no actor
            // hop. The Android backend's classes (`AndroidAppContext`,
            // `AndroidWindow`) are written with this in mind: their
            // mutable state is `nonisolated(unsafe)` and protected
            // by the single-thread access pattern (configure runs
            // once on the JNI worker thread, then the worker blocks
            // on the run semaphore — no concurrent writes).
            typealias UnisolatedConfigure = (any AppContext) throws -> Void
            let unisolated = unsafeBitCast(configure, to: UnisolatedConfigure.self)
            do {
                try unisolated(context)
            } catch {
                swiftpwa_android_log("configure threw: \(error)")
            }

            // Block until `quit(exitCode:)` is invoked. The semaphore
            // is signalled by `AndroidAppContext.completeRun`, which
            // the JNI quit trampoline calls when the Activity's
            // `onDestroy` runs.
            context.runSemaphore.wait()

            // Protocol contract is `-> Never`. Calling `exit()` here
            // tears down the JVM process; the Activity has already
            // been destroyed by the time we get here (since the
            // semaphore was signalled from `onDestroy`'s teardown
            // path), so no UI cleanup is leaked.
            exit(context.pendingExitCode ?? 0)
        }

        private func installMainThreadHook() {
            // The Swift-side runner that the JNI layer invokes once
            // the Java `Handler` posts our runnable. Unboxes the
            // closure and runs it. Always called on the JVM main
            // thread (Looper.getMainLooper()).
            swiftpwa_android_set_main_runner { boxPtr in
                guard let boxPtr else { return }
                let box = Unmanaged<MainBox>.fromOpaque(boxPtr).takeRetainedValue()
                box.body()
            }

            MainThread.setHook { body in
                let box = Unmanaged.passRetained(MainBox(body)).toOpaque()
                swiftpwa_android_post_main(box)
            }
        }
    }

    /// Heap-boxed closure ferried from `MainThread.run` through the
    /// JNI hop to `Handler.post`. Mirrors Windows' `ClosureBox`.
    final class MainBox: @unchecked Sendable {
        let body: @Sendable () -> Void
        init(_ body: @escaping @Sendable () -> Void) { self.body = body }
    }
#endif
