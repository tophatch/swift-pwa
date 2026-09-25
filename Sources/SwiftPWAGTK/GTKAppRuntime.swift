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
            // The name the bundler wrote into the `.desktop` entry beside this
            // binary, before anything asks for `app.name` or
            // `app.documentsDir`. A `swift build` binary has none.
            if let executable = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") {
                AppPlugin.setBundledDisplayName(
                    DesktopEntry.installedName(forExecutable: URL(fileURLWithPath: executable))
                )
            }
            var argc: Int32 = 0
            gtk_init(&argc, nil)
            installMainThreadHook()
            attachMainQueueToGTKLoop()
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
            // A deep link arrives the same way, via the `x-scheme-handler/…`
            // association and `Exec=… %U` — a separate channel, since a URL to
            // route isn't a document to read.
            OpenURL.emit(OpenURL.launchURLs(), on: context.events)
            // Opt-in dev/test control socket. After `configure` so the app's
            // first window already exists when a driver connects; a no-op
            // unless SWIFT_PWA_DRIVE names a port (and absent entirely from
            // release builds).
            // The agent surface's indicator: a runtime-owned status item, so a user
            // can see access is open (and close it) without the app's cooperation.
            AgentIndicator.installTray { SystemTray() }
            // A backgrounded driven run is applied by the window itself (off
            // screen, no focus on map); say so, so `capabilities.background`
            // reports what actually happened rather than what was asked for.
            if DriverBackground.isRequested { DriverBackground.markHonoured() }
            AppDriver.startIfRequested(context, backend: "gtk3")
            gtk_main()
            exit(context.pendingExitCode ?? 0)
        }
    }

    /// Route `MainThread.run` through `g_idle_add`, which schedules a callback
    /// to fire on the GTK main thread the next time the event loop is idle.
    ///
    /// File-scope rather than a method on the runtime so a GUI-gated test can
    /// install the same hook: without it `MainThread.run` falls back to
    /// libdispatch and deferred WebKit calls land on a worker thread at an
    /// arbitrary later moment, after the window that owns the view may already
    /// be gone (#187). See ``withGTKMainThreadForTesting(_:)``.
    func installMainThreadHook() {
        MainThread.setHook { body in
            let box = Unmanaged.passRetained(GTKMainThreadJob(body)).toOpaque()
            g_idle_add(gtkMainThreadTrampoline, box)
        }
    }

    /// Let an app's own `@MainActor` code run: watch libdispatch's main-queue
    /// handle from the GTK main loop and drain it when it signals.
    ///
    /// ``installMainThreadHook()`` above covers *swift-pwa's* UI work. This
    /// covers the app's, which swift-pwa never sees: off Apple, `MainActor` is
    /// backed by libdispatch's main queue, `gtk_main()` drains nothing, and an
    /// adopting app's `await MainActor.run { … }` therefore never returns —
    /// silently (#216). The watch is on the default `GMainContext`, the one
    /// `gtk_main()` iterates, so a modal `gtk_dialog_run` keeps servicing it too.
    ///
    /// Attaching costs nothing while the app has no main-actor work: the
    /// handle only becomes readable once something is enqueued.
    func attachMainQueueToGTKLoop() {
        guard let fd = PlatformMainQueue.handle else {
            RuntimeDiagnostics.emit(
                "swift-pwa: libdispatch has no main-queue handle; the app's own "
                    + "@MainActor code will not run (see docs/linux-setup.md)."
            )
            return
        }
        g_unix_fd_add(fd, G_IO_IN, { _, _, _ in
            PlatformMainQueue.drain()
            return gboolean(1) // G_SOURCE_CONTINUE
        }, nil)
    }

    /// Test-only: initialize GTK without entering `gtk_main()`, so
    /// `SWIFT_PWA_LINUX_GUI`-gated integration tests can construct a
    /// `GTKWindow`. `gtk_init` is safe to call more than once.
    ///
    /// Deliberately does **not** install the `g_idle_add` dispatch hook: the
    /// hook only delivers while something pumps the loop, and `MainThread.run`
    /// is global, so leaving one installed would hang every later test that
    /// awaits it (`WindowPluginTests`, `AppPluginTests`). A test that needs
    /// production ordering calls ``installMainThreadHook()`` itself and
    /// restores the default with `MainThread.resetHook()` when it is done.
    @MainActor
    func initGTKForTesting() {
        var argc: Int32 = 0
        gtk_init(&argc, nil)
    }

    /// Test-only: run `body` with GTK initialized and the production
    /// `g_idle_add` dispatch hook in place, restoring the default hook on the
    /// way out.
    ///
    /// A GUI test that lets a window go through teardown wants production
    /// ordering — deferred work queued into the GMainContext, run on the GTK
    /// main thread when the test pumps — rather than the default hook's
    /// libdispatch worker firing at an arbitrary later moment. The restore is
    /// the point of the wrapper: `MainThread`'s hook is process-global, and a
    /// GTK hook left installed hangs every later test that awaits
    /// `MainThread.run` without pumping.
    ///
    /// Take care that `body` does not suspend: the hook is global, so a test
    /// that yields the main actor between installing and restoring it would
    /// leave the hook in place for whatever runs next. The closure is
    /// deliberately non-`async` so that cannot happen by accident.
    @MainActor
    func withGTKMainThreadForTesting<T>(_ body: () throws -> T) rethrows -> T {
        initGTKForTesting()
        installMainThreadHook()
        defer { MainThread.resetHook() }
        return try body()
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
