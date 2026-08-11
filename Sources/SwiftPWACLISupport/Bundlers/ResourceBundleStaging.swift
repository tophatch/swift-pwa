import Foundation

/// SwiftPM resource bundles (`<package>_<target>.bundle` on Apple,
/// `<package>_<target>.resources` elsewhere) that a `swift build` leaves beside
/// the binary, and where each bundler puts them.
///
/// swift-pwa's own runtime deliberately produces none — `bridge.js` is compiled
/// into the binary (see `BridgeScript`) precisely because a resource bundle
/// can't be reached from inside an app bundle. But an adopter's target or a
/// third-party dependency can still declare `resources:`, and until 0.9.10 no
/// desktop bundler staged them at all: the built app read them out of the build
/// machine's `.build/`, which works right up until the app is moved to another
/// machine and then hard-crashes on launch.
enum ResourceBundles {
    /// The resource bundles sitting in `directory` (a `swift build` bin dir).
    static func found(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".bundle") || $0.hasSuffix(".resources") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    /// Copy them into `destination`, replacing any earlier copy. Returns the
    /// staged names for reporting.
    @discardableResult
    static func stage(_ bundles: [URL], into destination: URL) throws -> [String] {
        guard !bundles.isEmpty else { return [] }
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for bundle in bundles {
            let target = destination.appendingPathComponent(bundle.lastPathComponent)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: bundle, to: target)
        }
        return bundles.map(\.lastPathComponent)
    }

    /// The macOS-only caveat: `Contents/Resources` is the only signable place to
    /// put these, and it is *not* where SwiftPM's generated `Bundle.module`
    /// accessor looks (it resolves against `Bundle.main.bundleURL` — the bundle
    /// root, which codesign rejects as unsealed content). So the files travel
    /// with the app, but reaching them needs a path, not `Bundle.module`.
    static func reportAppBundleCaveat(_ names: [String]) {
        guard !names.isEmpty else { return }
        print("note: staged \(names.count) SwiftPM resource bundle(s) into Contents/Resources: "
            + names.joined(separator: ", "))
        print("      Read those files by path — Bundle.module resolves against the .app root, which "
            + "codesign won't seal.")
    }
}
