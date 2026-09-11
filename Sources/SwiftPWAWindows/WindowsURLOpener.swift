#if os(Windows)
    import CWebView2Shim
    import Foundation
    import SwiftPWACore

    /// ``URLOpener`` on Windows, via `ShellExecuteW` — the default browser for
    /// `http(s)`, whichever app is registered for a custom scheme.
    ///
    /// `ShellExecuteW` answers with a fake `HINSTANCE` whose value is an error
    /// code at or below 32; the shim reduces that to a plain success flag, so
    /// a scheme nothing claims comes back `false` rather than as a failure.
    public struct WindowsURLOpener: URLOpener {
        public init() {}

        public func open(_ url: URL) async -> Bool {
            let absolute = url.absoluteString
            return await MainThread.run {
                absolute.withCString { swiftpwa_w2_open_external($0) != 0 }
            }
        }
    }
#endif
