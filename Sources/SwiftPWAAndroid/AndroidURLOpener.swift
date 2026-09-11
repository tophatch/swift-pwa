#if os(Android)
    import Foundation
    import SwiftPWACore

    /// ``URLOpener`` on Android: `Intent.ACTION_VIEW` through the Kotlin
    /// bridge, which is the same helper the navigation policy uses — so
    /// `system.openURL` and a link out of the app take one route.
    ///
    /// An RPC rather than a direct call because `startActivity` is a JVM API
    /// needing the Activity, exactly like `clipboard.*` and `secrets.*`.
    public struct AndroidURLOpener: URLOpener {
        public init() {}

        public func open(_ url: URL) async -> Bool {
            struct Args: Encodable { let url: String }
            struct Result: Decodable { let opened: Bool }
            do {
                return try await AndroidRPC.call(
                    "system.openURL", Args(url: url.absoluteString), as: Result.self
                ).opened
            } catch {
                // The RPC itself failing is a runtime fault, not "no handler"
                // — but the page asked a yes/no question, and there is no
                // navigation left to fail. Report it and answer honestly.
                RuntimeDiagnostics.emit("swift-pwa: system.openURL failed: \(error)")
                return false
            }
        }
    }
#endif
