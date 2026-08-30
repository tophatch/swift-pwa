import Foundation

/// Resolves `pwa://localhost/...` (and the equivalent virtual-host) URLs to
/// file URLs / mime types for the custom URL scheme handlers in each
/// backend.
///
/// Originally a single-root value type; now a small **mount table** so the
/// bundle and additional writable roots (extracted content packs) can be
/// served on the *same* scheme/host under different path prefixes. The
/// bundle is always the `/` mount; `mount(_:at:)` adds more. Longest
/// matching prefix wins, and each mount keeps its own path-traversal guard.
///
/// It's a `final class` (not a value type) so the instance a backend hands
/// its scheme handler at window-creation time is the same one
/// `AppContext.serveDirectory` mutates later — a pack mounted at runtime is
/// visible to in-flight requests without re-registering anything. Thread
/// safety via `NSLock` (`resolve` runs on the platform UI thread; mounts may
/// be added from `configure`/command handlers).
public final class AssetProvider: @unchecked Sendable {
    public let scheme: String // "pwa"
    public let host: String // "localhost"

    private let lock = NSLock()
    private var mounts: [Mount]

    private struct Mount {
        let prefix: String // normalized: "/" or "/foo" (no trailing slash)
        let root: URL
        let writable: Bool
        /// SPA history-routing fallback (only ever set on the `/` bundle
        /// mount): when a request under this mount names no file on disk and
        /// looks like a client-side route, serve `fallbackDocument` instead of
        /// 404ing. `false` on served-pack mounts.
        var spaFallback: Bool = false
        /// The document served for an SPA-fallback hit (the bundle entry, e.g.
        /// `index.html`), relative to `root`.
        var fallbackDocument: String = "index.html"
    }

    public init(scheme: String = "pwa", host: String = "localhost", root: URL) {
        self.scheme = scheme
        self.host = host
        // The bundle is the read-only root mount.
        mounts = [Mount(prefix: "/", root: root.standardizedFileURL, writable: false)]
    }

    /// Create a router with **no** bundle mount yet. Used when the provider
    /// is owned by `AppContext` and shared across windows: the context
    /// creates it up front, then the first `.bundled` window installs the
    /// `/` mount via `setBundleRoot(_:)`. Until then `resolve` returns nil
    /// for everything (a `.remote`-only app needs no bundle root).
    public init(scheme: String = "pwa", host: String = "localhost") {
        self.scheme = scheme
        self.host = host
        mounts = []
    }

    /// Install (or replace) the read-only bundle `/` mount. Idempotent for
    /// the common case where every window loads the same bundle directory;
    /// the last writer wins if windows somehow disagree.
    ///
    /// `spaFallback` / `fallbackDocument` opt the bundle into single-page-app
    /// history routing — see ``WindowContent/bundled(directory:entry:spaFallback:)``
    /// and ``resolve(_:)``.
    public func setBundleRoot(_ root: URL, spaFallback: Bool = false, fallbackDocument: String = "index.html") {
        lock.lock(); defer { lock.unlock() }
        mounts.removeAll { $0.prefix == "/" }
        mounts.append(Mount(
            prefix: "/", root: root.standardizedFileURL, writable: false,
            spaFallback: spaFallback, fallbackDocument: fallbackDocument
        ))
    }

    /// The bundle root (the `/` mount) — exposed for the rare caller that
    /// needs the on-disk directory rather than a resolved URL.
    public var root: URL {
        lock.lock(); defer { lock.unlock() }
        return mounts.first { $0.prefix == "/" }?.root ?? URL(fileURLWithPath: "/")
    }

    public struct Resolved: Sendable {
        public let fileURL: URL
        public let mimeType: String
        /// Size in bytes — handlers use it for `Content-Length` and to
        /// answer `Range` requests without a second `stat`.
        public let fileSize: Int64

        public init(fileURL: URL, mimeType: String, fileSize: Int64) {
            self.fileURL = fileURL
            self.mimeType = mimeType
            self.fileSize = fileSize
        }
    }

    /// Mount an additional directory at `prefix` (e.g. `/packs`), served on
    /// the same scheme/host as the bundle. Re-mounting the same prefix
    /// replaces it. `writable` is metadata for callers; the handler only
    /// ever reads.
    public func mount(_ root: URL, at prefix: String, writable: Bool = true) {
        let normalized = Self.normalize(prefix)
        // `/` is reserved for the bundle (use `setBundleRoot`); a served mount
        // must have its own non-root prefix so it can't shadow the whole app.
        guard normalized != "/" else { return }
        lock.lock(); defer { lock.unlock() }
        mounts.removeAll { $0.prefix == normalized }
        mounts.append(Mount(prefix: normalized, root: root.standardizedFileURL, writable: writable))
    }

    /// Remove a previously-mounted prefix. The bundle `/` mount can't be
    /// removed.
    public func unmount(at prefix: String) {
        let normalized = Self.normalize(prefix)
        guard normalized != "/" else { return }
        lock.lock(); defer { lock.unlock() }
        mounts.removeAll { $0.prefix == normalized }
    }

    /// Resolve a request URL. Returns nil if the URL is outside the
    /// configured scheme/host, matches no mount, escapes a mount's root, or
    /// names something that isn't a regular file.
    public func resolve(_ url: URL) -> Resolved? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        guard let urlHost = url.host?.lowercased(), urlHost == host else { return nil }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }

        // Longest prefix first, so `/packs/...` beats the `/` bundle mount.
        let ordered: [Mount] = {
            lock.lock(); defer { lock.unlock() }
            return mounts.sorted { $0.prefix.count > $1.prefix.count }
        }()

        for mount in ordered {
            guard let relative = Self.relativePath(of: path, under: mount.prefix) else { continue }
            let candidate = mount.root.appendingPathComponent(relative).standardizedFileURL
            // Per-mount traversal guard: candidate must stay within root.
            let rootPath = mount.root.path
            let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard candidate.path == rootPath || candidate.path.hasPrefix(rootPrefix) else { continue }
            if let size = Self.regularFileSize(candidate) {
                return Resolved(fileURL: candidate, mimeType: Self.mimeType(for: candidate), fileSize: size)
            }
            // No file on disk. If this mount opts into SPA history routing and
            // the request looks like a client-side route (not an asset), serve
            // its fallback document instead of falling through to a 404 — so a
            // hard reload / deep-link of `/settings` loads the app. Only the
            // bundle `/` mount ever sets `spaFallback`.
            if mount.spaFallback, Self.looksLikeNavigation(path) {
                let fallback = mount.root.appendingPathComponent(mount.fallbackDocument).standardizedFileURL
                if let size = Self.regularFileSize(fallback) {
                    return Resolved(
                        fileURL: fallback, mimeType: Self.mimeType(for: fallback), fileSize: size
                    )
                }
            }
        }
        return nil
    }

    /// Whether `url` falls under a mount added via ``mount(_:at:)`` (a
    /// served pack), as opposed to the bundle `/` root or no mount at all.
    ///
    /// The Windows backend uses this to decide, per `WebResourceRequested`,
    /// whether to answer the request itself (true → resolve + range-serve the
    /// served directory) or let the native `SetVirtualHostNameToFolderMapping`
    /// serve the bundle (false). Scheme/host must still match.
    public func isServedPrefix(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == scheme else { return false }
        guard let urlHost = url.host?.lowercased(), urlHost == host else { return false }
        var path = url.path
        if path.isEmpty { path = "/" }
        let servedPrefixes: [String] = {
            lock.lock(); defer { lock.unlock() }
            return mounts.compactMap { $0.prefix == "/" ? nil : $0.prefix }
        }()
        for prefix in servedPrefixes where path == prefix || path.hasPrefix(prefix + "/") {
            return true
        }
        return false
    }

    /// The SPA-fallback resolution for `url` **only**: the bundle entry
    /// document when `url` names no file on disk, the bundle `/` mount opted
    /// into SPA fallback, and the path looks like a client-side route. Returns
    /// nil for a real file (so the caller keeps serving those its own way) and
    /// for a missing asset with an extension (an honest 404).
    ///
    /// The counterpart to the fallback baked into ``resolve(_:)``, for backends
    /// whose bundle is served **natively** (Windows' `SetVirtualHostNameTo`
    /// `FolderMapping`) rather than through `resolve` — they consult this in
    /// their resource-interception path to answer a route the native mapping
    /// would 404. Only applies to the bundle `/` mount.
    public func spaFallback(for url: URL) -> Resolved? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        guard let urlHost = url.host?.lowercased(), urlHost == host else { return nil }
        var path = url.path
        if path.isEmpty { path = "/" }
        guard Self.looksLikeNavigation(path) else { return nil }

        let bundle: Mount? = {
            lock.lock(); defer { lock.unlock() }
            return mounts.first { $0.prefix == "/" }
        }()
        guard let bundle, bundle.spaFallback else { return nil }

        // A real file at this exact path is not a fallback case.
        let relative = String(path.drop(while: { $0 == "/" }))
        let direct = bundle.root.appendingPathComponent(relative).standardizedFileURL
        if Self.regularFileSize(direct) != nil { return nil }

        let fallback = bundle.root.appendingPathComponent(bundle.fallbackDocument).standardizedFileURL
        guard let size = Self.regularFileSize(fallback) else { return nil }
        return Resolved(fileURL: fallback, mimeType: Self.mimeType(for: fallback), fileSize: size)
    }

    // MARK: - Helpers

    /// The path *under* `prefix`, or nil if `path` isn't covered by it.
    /// `/` covers everything; `/foo` covers `/foo` and `/foo/...`.
    private static func relativePath(of path: String, under prefix: String) -> String? {
        if prefix == "/" {
            return String(path.drop(while: { $0 == "/" }))
        }
        if path == prefix { return "" }
        if path.hasPrefix(prefix + "/") { return String(path.dropFirst(prefix.count + 1)) }
        return nil
    }

    /// Heuristic for "this request is a client-side route, not a file":
    /// the last path segment has no extension (`/settings`, `/users/42`,
    /// `/app/`). An asset request (`/assets/app.abc.js`, `/logo.png`,
    /// `/data.json`) has one, so it still 404s honestly rather than being
    /// masked by an HTML body — the standard SPA-fallback rule that keeps a
    /// missing chunk from silently returning `index.html`.
    public static func looksLikeNavigation(_ path: String) -> Bool {
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        return !last.contains(".")
    }

    private static func normalize(_ prefix: String) -> String {
        var p = prefix
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Byte size of a regular file at `url`, or nil if it's missing or a
    /// directory (so a directory request 404s rather than 500-ing in the
    /// handler's `Data(contentsOf:)`).
    private static func regularFileSize(_ url: URL) -> Int64? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
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
        // Every photo an iPhone takes is HEIC, so a served folder of pictures
        // hits these constantly. Whether they *render* is the engine's call and
        // not this table's: Apple's WebKit decodes both and sniffs them even
        // under the octet-stream fallback, while WebKitGTK decodes neither at
        // any type (those builds link no libheif/libavif). Declaring the real
        // type is still the honest answer — octet-stream is what a save or
        // download path, and any consumer that doesn't sniff, has to believe.
        case "heic": "image/heic"
        case "heif": "image/heif"
        case "avif": "image/avif"
        case "ico": "image/x-icon"
        case "wasm": "application/wasm"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        case "txt": "text/plain; charset=utf-8"
        case "map": "application/json; charset=utf-8"
        // Media types matter for the served-pack use case — browsers gate
        // `<video>`/`<audio>` streaming on a sensible content type.
        case "webm": "video/webm"
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "mp3": "audio/mpeg"
        case "m4a": "audio/mp4"
        case "ogg", "ogv": "video/ogg"
        case "wav": "audio/wav"
        default: "application/octet-stream"
        }
    }
}
