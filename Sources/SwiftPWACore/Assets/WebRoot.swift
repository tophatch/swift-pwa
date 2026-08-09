import Foundation

/// Finds the app's bundled `web/` directory.
///
/// This used to live in the `App.swift` that `swift-pwa init` generates, which
/// made it the *app's* problem: the Android asset path, the single-file-exe
/// case and the failure message were all copied into user code and frozen at
/// scaffold time, so a fix reached only projects created afterwards, an app
/// whose web directory sits outside its SwiftPM target had to hand-edit it, and
/// tooling had no way to influence it.
///
/// It's the runtime's problem now. ``WindowContent/bundledWeb(entry:spaFallback:fallbacks:)``
/// is the one line a generated `App.swift` needs.
public enum WebRoot {
    /// Points the runtime at a web directory of your choosing.
    ///
    /// **Debug builds only** — read solely where the app driver is compiled in.
    /// Honouring it in a shipped binary would let anyone aim an installed app
    /// at web content of their choice, which then runs with the full `invoke`
    /// surface behind it; that's a privilege-escalation route, not a feature.
    public static let environmentVariable = "SWIFT_PWA_WEB_ROOT"

    /// Where a bundled web root can be, in the order they're tried.
    ///
    /// The order matters: an explicit override beats the platform default, and
    /// the location `swift-pwa build` produces beats a SwiftPM resource bundle,
    /// so a real bundled app never accidentally serves a stale copy staged for
    /// development.
    public static func candidates(fallbacks: [URL] = []) -> [URL] {
        var roots: [URL] = []

        #if SWIFT_PWA_DRIVER
            if let override = ProcessInfo.processInfo.environment[environmentVariable],
               !override.isEmpty
            {
                roots.append(URL(fileURLWithPath: override))
            }
        #endif

        #if os(Android)
            // Served through the WebViewAssetLoader's virtual host rather than
            // read off disk, so this path is a token the backend recognises —
            // `exists` never holds for it.
            roots.append(URL(fileURLWithPath: "/android_asset/web"))
        #else
            // Where `swift-pwa build` puts it: Contents/Resources/web on macOS,
            // the bundle root on iOS, alongside the binary elsewhere.
            let base = Bundle.main.resourceURL ?? Bundle.main.bundleURL
            roots.append(base.appendingPathComponent("web"))
        #endif

        // An app that declares `resources: [.copy("web")]` passes
        // `Bundle.module.bundleURL` here — Core can't reach another module's
        // bundle itself.
        roots.append(contentsOf: fallbacks)
        return roots
    }

    /// The first candidate that exists on disk.
    ///
    /// - Throws: ``WebRootError/notFound(tried:)`` listing every path tried —
    ///   a blank window is the hardest possible thing to debug, and "it
    ///   wasn't in any of these five places" is a fixable message where
    ///   "missing index.html" is not.
    public static func resolve(fallbacks: [URL] = []) throws -> URL {
        #if os(Android)
            return candidates(fallbacks: fallbacks)[0]
        #else
            let tried = candidates(fallbacks: fallbacks)
            for root in tried where FileManager.default.fileExists(atPath: root.path) {
                return root
            }
            throw WebRootError.notFound(tried: tried)
        #endif
    }
}

public enum WebRootError: Error, CustomStringConvertible {
    case notFound(tried: [URL])

    public var description: String {
        switch self {
        case let .notFound(tried):
            """
            swift-pwa: couldn't find the app's web/ directory. Tried:
            \(tried.map { "  - \($0.path)" }.joined(separator: "\n"))

            A bundled app gets one from `swift-pwa build`. Running the bare SwiftPM binary \
            doesn't stage it — `swift-pwa dev` and `swift-pwa drive` point the app at your \
            source web/ instead, or declare `resources: [.copy("web")]` in Package.swift and \
            pass `Bundle.module.bundleURL` as a fallback.
            """
        }
    }
}

public extension WindowContent {
    /// The app's bundled web directory, wherever it turns out to be.
    ///
    /// ```swift
    /// let content = try WindowContent.bundledWeb(entry: "index.html")
    /// ```
    ///
    /// - Parameter fallbacks: extra roots to try last — pass
    ///   `Bundle.module.bundleURL.appendingPathComponent("web")` if the app
    ///   declares `web` as a SwiftPM resource.
    static func bundledWeb(
        entry: String = "index.html",
        spaFallback: Bool = false,
        fallbacks: [URL] = []
    ) throws -> WindowContent {
        // A single-file Windows build serves from an executable overlay, so
        // there's no directory to find and the backend ignores the path.
        if EmbeddedWebAssets.current != nil {
            return .bundled(directory: URL(fileURLWithPath: "."), entry: entry, spaFallback: spaFallback)
        }
        return try .bundled(
            directory: WebRoot.resolve(fallbacks: fallbacks),
            entry: entry,
            spaFallback: spaFallback
        )
    }
}
