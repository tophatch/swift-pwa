#if os(Linux)
    import CGtk3Shim
    import CWebKitGTK4Shim
    import Foundation
    import SwiftPWACore

    /// Linux-side runtime. Drives `gtk_main()`.
    ///
    /// Two important pieces of plumbing happen before `gtk_main()`:
    ///
    /// 1. **MainThread dispatch hook** — wires `MainThread.run` to
    ///    `g_idle_add` so that any code awaiting "run on the UI thread"
    ///    is actually scheduled into GTK's main loop. Without this,
    ///    `BridgeRuntime` and `WindowPlugin` would hang waiting on
    ///    Swift's MainActor executor (which isn't being pumped while
    ///    `gtk_main()` owns the main thread).
    /// 2. **`configure` closure** runs synchronously so any windows
    ///    are realized before the loop starts.
    public final class GTKAppRuntime: AppRuntime {
        public init() {}

        @MainActor
        public func run(
            _ configure: @escaping @MainActor @Sendable (any AppContext) throws -> Void
        ) throws -> Never {
            // Codegen headless catalog dump (roadmap #6): if SWIFT_PWA_DESCRIBE
            // is set, this writes the command catalog and exits before we touch
            // GTK; otherwise it returns and we launch normally.
            HeadlessDescribe.dumpIfRequested(configure)
            var argc: Int32 = 0
            gtk_init(&argc, nil)
            installMainThreadHook()
            let context = GTKAppContext.shared
            do {
                try configure(context)
            } catch {
                FileHandle.standardError.writeQuietly(
                    Data("swift-pwa: configure threw: \(error)\n".utf8)
                )
            }
            // Desktop "open with": a file association / CLI file argument
            // arrives as a launch argument (`.desktop` `Exec=… %F`). Emit it
            // (retained) so the WebView receives it once it subscribes to
            // `app.openFile`, matching the macOS/iOS Launch Services path.
            OpenFile.emit(OpenFile.launchFilePaths(), on: context.events)
            gtk_main()
            exit(context.pendingExitCode ?? 0)
        }

        /// Route `MainThread.run` through `g_idle_add`, which schedules
        /// a callback to fire on the GTK main thread the next time the
        /// event loop is idle.
        private func installMainThreadHook() {
            MainThread.setHook { body in
                let box = Unmanaged.passRetained(GTKMainThreadJob(body)).toOpaque()
                g_idle_add(gtkMainThreadTrampoline, box)
            }
        }
    }

    /// Test-only: initialize GTK without entering `gtk_main()`, so
    /// `SWIFT_PWA_LINUX_GUI`-gated integration tests can construct a
    /// `GTKWindow`. `gtk_init` is safe to call more than once.
    @MainActor
    func initGTKForTesting() {
        var argc: Int32 = 0
        gtk_init(&argc, nil)
    }

    /// Test-only: pump the global-default `GMainContext` for roughly
    /// `seconds` on the calling (main) thread, so `SWIFT_PWA_LINUX_GUI`-
    /// gated tests can let async GLib callbacks run without a full
    /// `gtk_main()`. Kept in parity with the GTK4 backend.
    @MainActor
    func pumpMainContextForTesting(seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = g_main_context_iteration(nil, gboolean(0)) // non-blocking
            usleep(2000)
        }
    }

    /// Heap-boxed `() -> Void` closure ferried across the C boundary.
    final class GTKMainThreadJob {
        let body: @Sendable () -> Void
        init(_ body: @escaping @Sendable () -> Void) { self.body = body }
    }

    /// `@convention(c)` GSourceFunc trampoline — invoked by GLib on the
    /// main thread. Returns `G_SOURCE_REMOVE` (0) so the callback fires
    /// exactly once per scheduled job.
    let gtkMainThreadTrampoline: @convention(c) (gpointer?) -> gboolean = { userData in
        guard let userData else { return gboolean(0) }
        let job = Unmanaged<GTKMainThreadJob>.fromOpaque(userData).takeRetainedValue()
        job.body()
        return gboolean(0) // G_SOURCE_REMOVE
    }
#endif
