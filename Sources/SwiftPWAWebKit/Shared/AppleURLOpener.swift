#if os(macOS) || os(iOS)
    import Foundation
    import SwiftPWACore
    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    /// ``URLOpener`` on Apple platforms: `NSWorkspace` on macOS,
    /// `UIApplication` on iOS.
    ///
    /// Both report whether the OS found a handler, which is the answer a page
    /// offering a deep link needs — `things:` opens on a machine with that app
    /// installed and comes back `opened: false` on one without, rather than
    /// failing or, as it did before this existed, doing nothing at all.
    ///
    /// `UIApplication.canOpenURL` is deliberately not pre-checked: on iOS it
    /// requires every scheme to be listed in `LSApplicationQueriesSchemes` and
    /// returns `false` for anything absent, so consulting it would turn a
    /// declared scheme into a silent refusal. `open` itself needs no such
    /// declaration.
    public struct AppleURLOpener: URLOpener {
        public init() {}

        public func open(_ url: URL) async -> Bool {
            #if os(macOS)
                await MainActor.run { NSWorkspace.shared.open(url) }
            #else
                await withCheckedContinuation { continuation in
                    Task { @MainActor in
                        UIApplication.shared.open(url, options: [:]) { opened in
                            continuation.resume(returning: opened)
                        }
                    }
                }
            #endif
        }
    }
#endif
