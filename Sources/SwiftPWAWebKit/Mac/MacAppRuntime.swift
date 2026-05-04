#if os(macOS)
    import AppKit
    import Foundation
    import SwiftPWACore

    /// macOS-side runtime. Owns the singleton `MacAppContext` and drives
    /// `NSApplication.run()`. The `configure` closure is scheduled as a
    /// `Task @MainActor` and runs once the AppKit run loop is live, so
    /// it's safe to create windows from inside it.
    @MainActor
    public final class MacAppRuntime {
        public static let shared = MacAppRuntime()
        public let context = MacAppContext()
        private var didStartConfigure = false

        private init() {}

        public func bootstrap(
            configure: @escaping @MainActor @Sendable (any AppContext) async throws -> Void
        ) {
            guard !didStartConfigure else { return }
            didStartConfigure = true
            let ctx = context
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)

            // Configure runs once the run loop is live.
            Task { @MainActor in
                do {
                    try await configure(ctx)
                } catch {
                    FileHandle.standardError.write(
                        Data("swift-pwa: configure threw: \(error)\n".utf8)
                    )
                }
                NSApp.activate(ignoringOtherApps: true)
            }
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
