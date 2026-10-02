import Foundation

/// The page a window comes back to when the system brings it back: iPadOS
/// reconnects a scene it disconnected to reclaim memory, and restores an app's
/// windows when it relaunches. The window is rebuilt from the app's main
/// `WindowConfig`, so what it showed last has to be carried separately and
/// applied to that config's content.
package enum RestoredPage {
    /// `content` pointed at `url`, when `url` is a page of that content: the
    /// bundle for a bundled window, the same origin for a remote one. Anything
    /// else (a page the window left the app for, the blank document a closing
    /// window departs to) gives back `content` unchanged, so a window never
    /// comes back somewhere the app didn't send it.
    package static func content(_ content: WindowContent, restoring url: URL?) -> WindowContent {
        guard let url else { return content }
        switch content {
        case let .bundled(directory, _, spaFallback):
            guard url.scheme == "pwa", url.host == "localhost",
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { return content }
            var page = String(parts.percentEncodedPath.drop { $0 == "/" })
            guard !page.isEmpty else { return content }
            if let query = parts.percentEncodedQuery { page += "?" + query }
            if let fragment = parts.percentEncodedFragment { page += "#" + fragment }
            return .bundled(directory: directory, entry: page, spaFallback: spaFallback)
        case let .remote(base):
            guard let origin = WebOrigin(url), origin == WebOrigin(base) else { return content }
            return .remote(url)
        }
    }
}
