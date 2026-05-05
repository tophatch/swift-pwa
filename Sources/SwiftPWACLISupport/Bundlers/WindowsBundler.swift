import ArgumentParser
import Foundation

/// Builds a portable Windows folder bundle.
///
/// MSIX / Appx packaging needs `makeappx.exe` + a signing cert and is
/// the v0.3 target. v0.2 ships a portable layout that works on any
/// Windows 10 / 11 box with the WebView2 Runtime installed:
///
/// ```
/// build/
///   <Name>/
///     <Name>.exe
///     web/
///       index.html
///       …
///     pwa.json
/// ```
///
/// `WebView2Loader.dll` is NOT shipped — the static loader
/// (`WebView2LoaderStatic.lib`) is linked into the binary by the
/// `CWebView2Shim` target, so apps don't need a sidecar DLL. The
/// WebView2 Runtime itself is present by default on Windows 11 and
/// Windows 10 21H2+; older boxes prompt the user via the runtime
/// detection in `WindowsAppRuntime`.
///
/// **Cross-host requirement:** runs on Windows only. From a macOS or
/// Linux dev box, `swift run swift-pwa build --target windows` errors
/// out before invoking `swift build`, because the Swift-on-Windows
/// SDK isn't reachable cross-platform. This matches the iOS bundler,
/// which also requires running on the platform vendor's host.
struct WindowsBundler {
    let manifest: PWAManifest
    let projectRoot: URL
    let outputDir: URL

    func build() async throws -> URL {
        #if !os(Windows)
            throw ValidationError("""
            swift-pwa: --target windows must be run on a Windows host.
            See docs/windows-setup.md for the toolchain (Swift 6, VS Build Tools, WebView2 SDK).
            """)
        #else
            try await Shell.run(
                "swift", ["build", "-c", "release"], cwd: projectRoot
            )
            let exeName = manifest.name + ".exe"
            let binary = projectRoot
                .appendingPathComponent(".build")
                .appendingPathComponent("release")
                .appendingPathComponent(exeName)
            guard FileManager.default.fileExists(atPath: binary.path) else {
                throw BundlerError.binaryMissing(binary)
            }

            let bundleDir = outputDir.appendingPathComponent(manifest.name)
            if FileManager.default.fileExists(atPath: bundleDir.path) {
                try FileManager.default.removeItem(at: bundleDir)
            }
            try FileManager.default.createDirectory(
                at: bundleDir, withIntermediateDirectories: true
            )

            try FileManager.default.copyItem(
                at: binary,
                to: bundleDir.appendingPathComponent(exeName)
            )

            let webSrc = projectRoot.appendingPathComponent(manifest.web.directory)
            if FileManager.default.fileExists(atPath: webSrc.path) {
                try FileManager.default.copyItem(
                    at: webSrc,
                    to: bundleDir.appendingPathComponent("web")
                )
            }

            // pwa.json copied so runtime-side config knows where the
            // web bundle lives. (The CLI's `init` template has the
            // app pass `WindowContent.bundled` resolved from the
            // executable's directory; copying pwa.json keeps the
            // wiring source-of-truth aligned with the bundle.)
            let manifestSrc = projectRoot.appendingPathComponent("pwa.json")
            if FileManager.default.fileExists(atPath: manifestSrc.path) {
                try FileManager.default.copyItem(
                    at: manifestSrc,
                    to: bundleDir.appendingPathComponent("pwa.json")
                )
            }
            return bundleDir
        #endif
    }
}
