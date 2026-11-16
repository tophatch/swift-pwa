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

    /// Where `bridge.js` sends this origin's media (#349): `base` is a
    /// ``LoopbackMediaServer``'s URL, `origin` the app's own (`pwa://localhost`).
    package struct MediaRoute: Equatable {
        package let base: String
        package let origin: String

        package init(base: String, origin: String) {
            self.base = base
            self.origin = origin
        }
    }

    package static let mediaRouteMarker = "/*__SWIFT_PWA_MEDIA_ROUTE__*/null"

    /// The runtime with media routed to a loopback server — the GTK backends,
    /// whose media player can't read the app's scheme. A closure constant
    /// rather than a page global, so the token never sits on `window`.
    package static func source(mediaRoute: MediaRoute?) -> String {
        guard let mediaRoute else { return BridgeJSData.source }
        return BridgeJSData.source.replacingOccurrences(
            of: mediaRouteMarker,
            with: "{\"base\":\(jsString(mediaRoute.base)),\"origin\":\(jsString(mediaRoute.origin))}"
        )
    }

    private static func jsString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case _ where scalar.value < 0x20 || scalar == "\u{2028}" || scalar == "\u{2029}":
                out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
