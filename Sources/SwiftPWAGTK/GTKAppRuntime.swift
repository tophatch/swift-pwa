#if os(Linux)
    import CGtk3Shim
    import CWebKitGTK4Shim
    import Foundation
    import SwiftPWACore

    /// Linux-side runtime. Drives `gtk_main()`. The configure closure
    /// is scheduled as a g_idle callback so it runs once the GTK loop
    /// is live (analogous to the Apple side using a Task that fires
    /// after `NSApplication.run()` starts).
    public final class GTKAppRuntime: AppRuntime {
        public init() {}

        @MainActor
        public func run(
            _ configure: @MainActor @Sendable (any AppContext) async throws -> Void
        ) throws -> Never {
            var argc: Int32 = 0
            gtk_init(&argc, nil)
            let context = GTKAppContext.shared
            // Run configure synchronously on the main thread before
            // entering gtk_main(). Async commands inside configure that
            // wait on actor messages still work because the actor
            // scheduler doesn't depend on gtk_main().
            let group = DispatchGroup()
            group.enter()
            Task { @MainActor in
                defer { group.leave() }
                do { try await configure(context) }
                catch {
                    FileHandle.standardError.write(
                        Data("swift-pwa: configure threw: \(error)\n".utf8)
                    )
                }
            }
            group.wait()
            gtk_main()
            exit(context.pendingExitCode ?? 0)
        }
    }
#endif
