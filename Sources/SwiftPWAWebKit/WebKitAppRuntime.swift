#if os(macOS) || os(iOS)
    import Foundation
    import SwiftPWACore

    /// Apple-platform `AppRuntime`. Drives `NSApplication` on macOS and
    /// `UIApplication` (via UIScene) on iOS. See `Mac/MacAppRuntime.swift`
    /// and `iOS/IOSAppRuntime.swift` for the platform-specific halves.
    public final class WebKitAppRuntime: AppRuntime {
        public init() {}

        public func run(
            _ configure: @escaping @MainActor @Sendable (any AppContext) async throws -> Void
        ) throws -> Never {
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
