// Umbrella module. Re-exports `SwiftPWACore` and exposes a single
// `runtime()` entry point that returns the platform-appropriate
// `AppRuntime` implementation.
//
// Users only ever import `SwiftPWA`.

@_exported import SwiftPWACore

#if canImport(WebKit) && (os(macOS) || os(iOS))
    @_exported import SwiftPWAWebKit
#elseif os(Linux)
    @_exported import SwiftPWAGTK
#elseif os(Windows)
    @_exported import SwiftPWAWindows
#endif

import Foundation

public enum SwiftPWA {
    /// Returns the platform-appropriate `AppRuntime`. Throws on
    /// unsupported platforms (Android remains a stub through v0.3).
    public static func runtime() throws -> any AppRuntime {
        #if canImport(WebKit) && (os(macOS) || os(iOS))
            return WebKitAppRuntime()
        #elseif os(Linux)
            return GTKAppRuntime()
        #elseif os(Windows)
            return WindowsAppRuntime()
        #else
            throw BridgeError(
                code: BridgeError.unimplemented,
                message: "swift-pwa has no runtime for this platform yet"
            )
        #endif
    }
}
