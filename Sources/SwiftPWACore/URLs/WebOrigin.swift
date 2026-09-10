import Foundation

/// The origin a window's own content lives on — scheme, host and port, the
/// three things that decide whether a navigation is still inside the app.
///
/// A window is not always on the bundle origin: `WindowContent.remote` points
/// a window at a real website, and an app pointed at a web app should be able
/// to navigate around that site freely. So "off-origin" is measured against
/// *this window's* content, not against `pwa://localhost`.
public struct WebOrigin: Sendable, Equatable, Hashable {
    public let scheme: String
    public let host: String
    public let port: Int?

    public init(scheme: String, host: String, port: Int? = nil) {
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        self.port = port
    }

    /// The origin of `url`, or `nil` if it has no host to compare (a `data:`
    /// or `about:` URL is not an origin any navigation can be measured
    /// against).
    public init?(_ url: URL) {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        self.init(scheme: scheme, host: host, port: url.port)
    }

    /// Whether `url` is on this origin. Same scheme, same host, same port.
    public func covers(_ url: URL) -> Bool {
        guard let other = WebOrigin(url) else { return false }
        return self == other
    }
}
