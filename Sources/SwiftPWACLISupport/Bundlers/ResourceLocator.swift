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
    /// SwiftPM names the resource bundle `<PackageName>_<TargetName>` with a
    /// platform-dependent extension: `.bundle` on Apple, `.resources` on
    /// swift-corelibs-foundation (Linux / Android / Windows). Try both.
    private static let bundleNames = [
        "swift-pwa_SwiftPWACLISupport.bundle",
        "swift-pwa_SwiftPWACLISupport.resources"
    ]

    /// Locate `resource` (a file or directory name) inside this module's
    /// resource bundle, searching every plausible location for a prebuilt
    /// or `swift run` binary. Returns `nil` (never traps) when no bundle is
    /// found — callers degrade gracefully.
    static func moduleResource(_ resource: String, withExtension ext: String? = nil) -> URL? {
        let fm = FileManager.default
        for dir in searchDirectories() {
            for bundleName in bundleNames {
                let bundleURL = dir.appendingPathComponent(bundleName)
                guard fm.fileExists(atPath: bundleURL.path), let bundle = Bundle(url: bundleURL) else {
                    continue
                }
                if let url = bundle.url(forResource: resource, withExtension: ext) {
                    return url
                }
            }
        }
        return nil
    }

    /// Directories that might hold the resource bundle, most-likely first.
    private static func searchDirectories() -> [URL] {
        var dirs: [URL] = []
        func add(executableDir: URL) {
            dirs.append(executableDir)
            // FHS install: binary in `…/bin`, resources in `…/share/swift-pwa`.
            dirs.append(executableDir.deletingLastPathComponent()
                .appendingPathComponent("share/swift-pwa"))
        }
        // The real executable's directory. On Linux/Android `/proc/self/exe`
        // is the reliable source — under `swift run`, `Bundle.main` does NOT
        // resolve to the `.build` dir where the bundle sits (that's why the
        // synthesized `Bundle.module` falls back to a compile-time path, which
        // a *prebuilt* binary can't reuse). On Apple, `executableURL` is right.
        #if os(Linux) || os(Android)
            if let real = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") {
                add(executableDir: URL(fileURLWithPath: real).deletingLastPathComponent())
            }
        #endif
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            add(executableDir: exe.deletingLastPathComponent())
        }
        // The same candidates `Bundle.module` itself consults first.
        if let res = Bundle.main.resourceURL { dirs.append(res) }
        dirs.append(Bundle.main.bundleURL)
        return dirs
    }
}
