#if os(macOS) || os(iOS)
    import Foundation
    import SwiftPWACore

    /// Apple-platform `AppRuntime`. Drives `NSApplication` on macOS and
    /// `UIApplication` (via UIScene) on iOS. See `Mac/MacAppRuntime.swift`
    /// and `iOS/IOSAppRuntime.swift` for the platform-specific halves.
    public final class WebKitAppRuntime: AppRuntime {
        public init() {}

        public func run(
            _ configure: @escaping @MainActor @Sendable (any AppContext) throws -> Void
        ) throws -> Never {
            // Codegen headless catalog dump (roadmap #6): if SWIFT_PWA_DESCRIBE
            // is set, this writes the command catalog and exits before any UI
            // bootstrap; otherwise it returns and we launch normally.
            MainActor.assumeIsolated { HeadlessDescribe.dumpIfRequested(configure) }
            #if os(macOS)
                MainActor.assumeIsolated { MacAppRuntime.shared.bootstrap(configure: configure) }
                MacAppRuntime.shared.runForever()
            #elseif os(iOS)
                IOSAppRuntime.shared.bootstrap(configure: configure)
                IOSAppRuntime.shared.runForever()
            #endif
        }
    }
#endif
