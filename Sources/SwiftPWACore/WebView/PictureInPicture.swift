import Foundation

/// Picture in picture for a page's `<video>`.
///
/// Only macOS needs this: its webview offers picture in picture through a
/// private WebKit preference alone, so an app opts in with `pwa.json`'s
/// `macos.picture_in_picture` rather than shipping a private selector in every
/// app. The CLI writes the opt-in into the bundle's `Info.plist`, and the
/// webview reads it at launch — on every build, not just at `init`.
public enum PictureInPicture {
    public static let infoPlistKey = "SwiftPWAPictureInPicture"

    /// How `drive` and `dev` pass the opt-in to a bare `swift build` binary,
    /// which has no `Info.plist` — without it a driven run reports picture in
    /// picture as unsupported while the bundled app offers it.
    public static let environmentVariable = "SWIFT_PWA_PICTURE_IN_PICTURE"

    /// Whether this app opted in, from its bundle or, for a build the tooling
    /// can drive, from the tooling.
    public static func isRequested(
        info: [String: Any]? = Bundle.main.infoDictionary,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if info?[infoPlistKey] as? Bool == true { return true }
        #if SWIFT_PWA_DRIVER
            return environment[environmentVariable] == "1"
        #else
            return false
        #endif
    }
}
