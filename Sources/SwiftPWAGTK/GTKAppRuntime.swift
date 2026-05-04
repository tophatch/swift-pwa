#if os(Linux)
    import CGtk3Shim
    import CWebKitGTK4Shim
    import Foundation
    import SwiftPWACore

    /// Linux-side runtime. Drives `gtk_main()`. The configure closure
    /// runs synchronously *before* `gtk_main()` enters its event loop,
    /// so any windows it creates are realized and shown by the time
    /// the loop starts servicing events.
    ///
    /// We deliberately avoid `Task { @MainActor in await configure(...) }`
    /// here: Swift's main-actor executor on Linux is libdispatch's main
    /// queue, which `gtk_main()` does not pump. Scheduling configure
    /// onto MainActor and waiting for it would deadlock.
    public final class GTKAppRuntime: AppRuntime {
        public init() {}

        @MainActor
        public func run(
            _ configure: @escaping @MainActor @Sendable (any AppContext) throws -> Void
        ) throws -> Never {
            var argc: Int32 = 0
            gtk_init(&argc, nil)
            let context = GTKAppContext.shared
            do {
                try configure(context)
            } catch {
                FileHandle.standardError.write(
                    Data("swift-pwa: configure threw: \(error)\n".utf8)
                )
            }
            gtk_main()
            exit(context.pendingExitCode ?? 0)
        }
    }
#endif
