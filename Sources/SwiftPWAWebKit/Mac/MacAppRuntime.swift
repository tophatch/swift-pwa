#if os(macOS)
    import AppKit
    import Foundation
    import SwiftPWACore

    /// macOS-side runtime. Owns the singleton `MacAppContext` and drives
    /// `NSApplication.run()`. The `configure` closure runs synchronously
    /// before `NSApp.run()` enters the AppKit event loop — windows it
    /// creates are visible from the moment the loop starts.
    @MainActor
    public final class MacAppRuntime {
        public static let shared = MacAppRuntime()
        public let context = MacAppContext()
        private var didStartConfigure = false

        private init() {}

        public func bootstrap(
            configure: @escaping @MainActor @Sendable (any AppContext) throws -> Void
        ) {
            guard !didStartConfigure else { return }
            didStartConfigure = true
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)

            // Route MainThread.run through DispatchQueue.main so the
            // bridge runtime can hop to the UI thread uniformly across
            // platforms. (The GTK side does the same with g_idle_add.)
            MainThread.setHook { body in
                if Thread.isMainThread {
                    body()
                } else {
                    DispatchQueue.main.async { body() }
                }
            }

            do {
                try configure(context)
            } catch {
                FileHandle.standardError.write(
                    Data("swift-pwa: configure threw: \(error)\n".utf8)
                )
            }
            NSApp.activate(ignoringOtherApps: true)
        }

        public func runForever() -> Never {
            NSApplication.shared.run()
            // NSApp.run() returns after orderly shutdown. Use the
            // exit code stashed by `MacAppContext.quit`, defaulting
            // to 0 on a clean termination.
            exit(context.pendingExitCode ?? 0)
        }
    }
#endif
