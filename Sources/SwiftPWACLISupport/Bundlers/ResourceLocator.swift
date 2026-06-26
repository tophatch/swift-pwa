import Foundation

/// Finds resources shipped in this module's SwiftPM resource bundle
/// **without** the trap that `Bundle.module` takes when the bundle is
/// absent.
///
/// `Bundle.module` is a synthesized accessor that calls `fatalError` if it
/// can't find `swift-pwa_SwiftPWACLISupport.bundle` next to the binary. A
/// prebuilt, single-file `swift-pwa` (the release artifact, or one moved by
/// `self-update`) has no co-located `.bundle`, so *touching* `Bundle.module`
/// at all crashes the CLI — before any graceful `guard let` can run. The
/// Android bundler hit exactly this resolving its vendored Gradle wrapper.
///
/// This replicates `Bundle.module`'s search manually, returns `nil` instead
/// of trapping, and additionally probes locations relative to the
/// **resolved** executable path (symlinks followed — a `/usr/local/bin`
/// install is often a symlink) plus the FHS `../share/swift-pwa` layout.
enum ResourceLocator {
    /// SwiftPM names the bundle `<PackageName>_<TargetName>.bundle`.
    private static let bundleName = "swift-pwa_SwiftPWACLISupport.bundle"

    /// Locate `resource` (a file or directory name) inside this module's
    /// resource bundle, searching every plausible location for a prebuilt
    /// or `swift run` binary. Returns `nil` (never traps) when no bundle is
    /// found — callers degrade gracefully.
    static func moduleResource(_ resource: String, withExtension ext: String? = nil) -> URL? {
        let fm = FileManager.default
        for dir in searchDirectories() {
            let bundleURL = dir.appendingPathComponent(bundleName)
            guard fm.fileExists(atPath: bundleURL.path), let bundle = Bundle(url: bundleURL) else {
                continue
            }
            if let url = bundle.url(forResource: resource, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    /// Directories that might hold the resource bundle, most-likely first.
    private static func searchDirectories() -> [URL] {
        var dirs: [URL] = []
        // The real executable's directory, symlinks resolved. Covers both
        // a `swift run` build (bundle sits beside the binary in
        // `.build/<config>/`) and a prebuilt binary that shipped its bundle.
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let exeDir = exe.deletingLastPathComponent()
            dirs.append(exeDir)
            // FHS install: binary in `…/bin`, resources in `…/share/swift-pwa`.
            dirs.append(exeDir.deletingLastPathComponent()
                .appendingPathComponent("share/swift-pwa"))
        }
        // The same candidates `Bundle.module` itself would consult.
        if let res = Bundle.main.resourceURL { dirs.append(res) }
        dirs.append(Bundle.main.bundleURL)
        return dirs
    }
}
