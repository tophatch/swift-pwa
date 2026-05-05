import ArgumentParser
import Foundation

// On Apple, `URLSession` lives in Foundation; on swift-corelibs-foundation
// (Linux + Windows) the networking pieces moved to a separate
// `FoundationNetworking` module. The bundler builds on every host
// because `SwiftPWACLISupport` isn't platform-gated, so import the
// extra module wherever it's available.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Builds a Windows artifact.
///
/// Two output formats:
///
///   * **Portable folder** (default): `build/<Name>/<Name>.exe`,
///     `web/`, `pwa.json`. Drop on any Windows 10 21H2+ / Windows 11
///     box that has the WebView2 Runtime, double-click the EXE.
///   * **MSIX package** (`--package-format msix`): a signed AppX/MSIX
///     package suitable for sideloading or Microsoft Store
///     submission. Requires `makeappx.exe` on PATH (Windows SDK) and,
///     for non-self-signed installs, a signing cert via
///     `--sign <thumbprint-or-pfx>`.
///
/// `WebView2LoaderStatic.lib` is linked into the binary by the
/// `CWebView2Shim` target, so apps don't need a sidecar
/// `WebView2Loader.dll`. The WebView2 Runtime itself is present by
/// default on Windows 11 and Windows 10 21H2+; older boxes either
/// install it manually or use `--bootstrap-webview2` (below).
///
/// `--bootstrap-webview2`: drops the Evergreen Bootstrapper
/// (`MicrosoftEdgeWebview2Setup.exe`, ~1.7 MB) next to the EXE.
/// `WindowsAppRuntime` detects a missing runtime at startup and, if
/// the bootstrapper is co-located, prompts the user to install via a
/// MessageBoxW + ShellExecuteEx with elevation. Self-contained
/// installs do *not* embed the runtime itself — that's an extra
/// ~120 MB and only legal under the WebView2 redistribution terms
/// for some scenarios — but the Evergreen Bootstrapper is freely
/// redistributable.
///
/// **Cross-host requirement:** runs on Windows only. From a macOS or
/// Linux dev box, `swift run swift-pwa build --target windows` errors
/// out before invoking `swift build`, because the Swift-on-Windows
/// SDK isn't reachable cross-platform. This matches the iOS bundler.
struct WindowsBundler {
    enum PackageFormat {
        case portable
        case msix
    }

    let manifest: PWAManifest
    let projectRoot: URL
    let outputDir: URL
    var packageFormat: PackageFormat = .portable
    var bootstrapWebView2: Bool = false
    var signIdentity: String?

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

            if bootstrapWebView2 {
                try await downloadBootstrapper(into: bundleDir)
            }

            switch packageFormat {
            case .portable:
                return bundleDir
            case .msix:
                return try await buildMSIX(stagingDir: bundleDir)
            }
        #endif
    }

    // MARK: - WebView2 Evergreen Bootstrapper

    /// `MicrosoftEdgeWebview2Setup.exe` is the official Evergreen
    /// Bootstrapper — a ~1.7 MB stub that downloads + installs the
    /// real runtime. The download URL is a Microsoft fwlink that
    /// redirects to the current production build. Microsoft permits
    /// redistribution of this file as part of an app installer; see
    /// <https://developer.microsoft.com/microsoft-edge/webview2/>
    /// "Distribution" terms.
    private func downloadBootstrapper(into bundleDir: URL) async throws {
        let url = URL(string: "https://go.microsoft.com/fwlink/p/?LinkId=2124703")!
        let dst = bundleDir.appendingPathComponent("MicrosoftEdgeWebview2Setup.exe")

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BundlerError.shell(
                -1,
                "WebView2 bootstrapper download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))"
            )
        }
        // Sanity-check: the bootstrapper is ~1.7 MB; anything under
        // 500 KB is almost certainly an HTML error page that returned
        // 200 from a misconfigured proxy.
        guard data.count > 500_000 else {
            throw BundlerError.shell(
                -1,
                "WebView2 bootstrapper download returned \(data.count) bytes — expected ~1.7 MB"
            )
        }
        try data.write(to: dst)
    }

    // MARK: - MSIX packaging

    /// Drive `makeappx.exe pack` (and optionally `signtool.exe sign`)
    /// against a staging tree containing the EXE, web bundle, an
    /// `AppxManifest.xml`, and a `Square150x150Logo.png` icon.
    ///
    /// The MSIX format requires a signed package for the OS to install
    /// it without developer-mode sideloading; we don't try to generate
    /// a self-signed cert on the fly (pwsh's `New-SelfSignedCertificate`
    /// is the documented path), so unsigned packages here are valid
    /// only on developer-mode boxes.
    private func buildMSIX(stagingDir: URL) async throws -> URL {
        // Generate AppxManifest.xml.
        let appxManifest = AppxManifestGenerator.render(manifest: manifest)
        try appxManifest.write(
            to: stagingDir.appendingPathComponent("AppxManifest.xml"),
            atomically: true,
            encoding: .utf8
        )

        // The MSIX schema requires at least a Square150x150Logo. If the
        // caller provided an icon, copy it; otherwise emit a 1x1
        // placeholder PNG so makeappx doesn't reject the manifest.
        let logoPath = stagingDir.appendingPathComponent("Square150x150Logo.png")
        if let icon = manifest.icon {
            let src = projectRoot.appendingPathComponent(icon)
            if FileManager.default.fileExists(atPath: src.path) {
                try FileManager.default.copyItem(at: src, to: logoPath)
            }
        }
        if !FileManager.default.fileExists(atPath: logoPath.path) {
            try Data(placeholderPNG).write(to: logoPath)
        }

        let msixURL = outputDir.appendingPathComponent("\(manifest.name).msix")
        if FileManager.default.fileExists(atPath: msixURL.path) {
            try FileManager.default.removeItem(at: msixURL)
        }

        try await Shell.run(
            "makeappx.exe",
            ["pack", "/d", stagingDir.path, "/p", msixURL.path, "/o"]
        )

        if let signIdentity {
            // signtool accepts a thumbprint via `/sha1` or a PFX via
            // `/f <path> /p <password>`. We treat the value as a
            // thumbprint when it's 40 hex chars, a PFX path otherwise.
            let isThumbprint = signIdentity.count == 40
                && signIdentity.allSatisfy(\.isHexDigit)
            let signArgs: [String] = isThumbprint
                ? ["sign", "/fd", "SHA256", "/sha1", signIdentity, msixURL.path]
                : ["sign", "/fd", "SHA256", "/f", signIdentity, msixURL.path]
            try await Shell.run("signtool.exe", signArgs)
        }

        return msixURL
    }

    /// 1x1 transparent PNG (67 bytes). Used as a placeholder
    /// `Square150x150Logo.png` when the caller didn't supply an
    /// `icon` in `pwa.json` — `makeappx` fails the schema check
    /// otherwise.
    private var placeholderPNG: [UInt8] {
        [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82
        ]
    }
}
