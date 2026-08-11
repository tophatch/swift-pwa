import Foundation

/// Loads the `bridge.js` runtime that backends inject into every webview.
/// Every backend calls this same loader so the JS surface is identical.
///
/// The text is compiled into the binary (`BridgeJSData`, generated from
/// `Resources/bridge.js` by `Scripts/regenerate-bridge-js.sh`) rather than read
/// from a SwiftPM resource bundle. A resource bundle can't travel inside an app
/// bundle: SwiftPM's generated `Bundle.module` accessor resolves it against
/// `Bundle.main.bundleURL`, which for a `.app` is the bundle root — the one
/// place codesign refuses to seal. Apps therefore read it out of the build
/// machine's `.build/` and died on launch anywhere else.
public enum BridgeScript {
    public static let globalName = "__SWIFT_PWA__"
    public static let messageHandlerName = "__SwiftPWA__post"

    /// The JS runtime as a string. Still `throws` for source compatibility
    /// with the resource-loading version this replaced; it can no longer fail.
    public static func source() throws -> String {
        BridgeJSData.source
    }
}
