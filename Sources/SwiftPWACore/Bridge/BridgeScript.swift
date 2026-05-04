import Foundation

/// Locates and loads the `bridge.js` runtime that backends inject into
/// every webview. The script is a resource of `SwiftPWACore`; both Apple
/// and GTK backends call this same loader so the JS surface is identical.
public enum BridgeScript {
    public static let globalName = "__SWIFT_PWA__"
    public static let messageHandlerName = "__SwiftPWA__post"

    /// The JS runtime as a string. Throws if the bundled resource is
    /// missing (which would indicate a build-system failure, not a
    /// recoverable runtime condition).
    public static func source() throws -> String {
        guard let url = Bundle.module.url(forResource: "bridge", withExtension: "js") else {
            throw BridgeError(
                code: BridgeError.handler,
                message: "bridge.js missing from SwiftPWACore bundle"
            )
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
