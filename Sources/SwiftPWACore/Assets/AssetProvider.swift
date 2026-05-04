import Foundation

/// Resolves `pwa://localhost/...` URLs to file URLs / mime types for the
/// custom URL scheme handlers in each backend.
public struct AssetProvider: Sendable {
    public let scheme: String // "pwa"
    public let host: String // "localhost"
    public let root: URL // directory containing the web bundle

    public init(scheme: String = "pwa", host: String = "localhost", root: URL) {
        self.scheme = scheme
        self.host = host
        self.root = root
    }

    public struct Resolved: Sendable {
        public let fileURL: URL
        public let mimeType: String
    }

    /// Resolve a `pwa://` request URL. Returns nil if the URL is outside
    /// the configured scheme/host or escapes the bundle root.
    public func resolve(_ url: URL) -> Resolved? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        guard let host = url.host?.lowercased(), host == self.host else { return nil }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        // Strip leading slash to make it relative.
        if path.hasPrefix("/") { path.removeFirst() }

        let candidate = root.appendingPathComponent(path).standardizedFileURL
        // Guard against path traversal: candidate must stay within root.
        let rootStd = root.standardizedFileURL.path
        guard candidate.path.hasPrefix(rootStd) else { return nil }
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }

        return Resolved(fileURL: candidate, mimeType: Self.mimeType(for: candidate))
    }

    public static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": "text/html; charset=utf-8"
        case "js", "mjs": "application/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        case "gif": "image/gif"
        case "ico": "image/x-icon"
        case "wasm": "application/wasm"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        case "txt": "text/plain; charset=utf-8"
        case "map": "application/json; charset=utf-8"
        default: "application/octet-stream"
        }
    }
}
