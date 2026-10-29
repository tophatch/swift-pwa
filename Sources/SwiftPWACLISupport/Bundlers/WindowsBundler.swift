import ArgumentParser
import Foundation
import SwiftPWACore

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
    var arch: AppxManifestGenerator.Architecture = .x64
    var bootstrapWebView2: Bool = false
    var signIdentity: String?
    var configuration: BuildConfiguration = .release
    /// Directories holding vendored native libraries this build links against
    /// — the llama.cpp / ONNX Runtime tiers swift-pwa resolves, the Vulkan
    /// SDK's `Lib`, plus the app's own `windows.native_library_dirs`. See
    /// ``NativeLibrarySearch``.
    var nativeLibraryDirs: [URL] = []
    /// Directories holding the headers for the libraries the app vendors
    /// itself (`windows.native_include_dirs`) — passed the same way as the
    /// WebView2 / WIL headers below, and needed for the same reason: `INCLUDE`
    /// no longer reaches the compile task (#219, #238).
    var nativeIncludeDirs: [URL] = []
    /// The build already compiled this configuration for this host — the
    /// headless permission check `build` runs first is a `swift run -c <same>`
    /// with the same search paths — so the exe is there and current.
    ///
    /// Not built a second time: that build compiled nothing, and on GitHub's
    /// Windows runners each `swift build` is a chance for Swift 6.4's build
    /// planner to stall for up to 45 minutes in `[Pre-planning 1 / N]`, in
    /// about half the runs measured, where a Windows 11 machine takes 4.5 s.
    /// The build still runs when the exe isn't where it should be.
    var alreadyBuilt = false

    /// Where the build put the exe, if it's there.
    ///
    /// SwiftPM creates `.build/release` as a symlink to the arch-qualified
    /// output directory (e.g. `.build/x86_64-unknown-windows-msvc/release/`).
    /// Symlink creation on Windows requires Administrator privileges *or*
    /// Developer Mode enabled in Settings — without either, SwiftPM emits the
    /// cosmetic "warning: unable to create symbolic link at .build\release"
    /// and the symlink simply doesn't exist. So the binary is looked for
    /// through the symlink first, then in the first `*-windows-msvc` arch
    /// directory (covers x86_64 and aarch64 hosts). Developer Mode isn't
    /// required because it's a machine-wide setting, often unavailable on CI
    /// runners or shared boxes.
    static func builtBinary(exeName: String, buildDir: URL, configuration: BuildConfiguration) -> URL? {
        let fm = FileManager.default
        let symlinkBinary = buildDir.appendingPathComponent(configuration.swiftPMValue).appendingPathComponent(exeName)
        if fm.fileExists(atPath: symlinkBinary.path) { return symlinkBinary }
        guard let archDir = (try? fm.contentsOfDirectory(at: buildDir, includingPropertiesForKeys: nil))?
            .first(where: { $0.lastPathComponent.hasSuffix("-windows-msvc") && !$0.lastPathComponent.hasPrefix(".") })
        else { return nil }
        let candidate = archDir.appendingPathComponent(configuration.swiftPMValue).appendingPathComponent(exeName)
        return fm.fileExists(atPath: candidate.path) ? candidate : nil
    }

    func build() async throws -> URL {
        #if !os(Windows)
            throw ValidationError("""
            swift-pwa: --target windows must be run on a Windows host.
            See docs/windows-setup.md for the toolchain (Swift 6, VS Build Tools, WebView2 SDK).
            """)
        #else
            // WebView2's headers and its loader's import library both reach
            // the build as flags. They rode on INCLUDE / LIB until Swift 6.4's
            // build engine stopped passing either to the tasks that need them
            // — measured on a real Windows box, with a control: a header only
            // on INCLUDE is `file not found`, and the same header behind
            // `-Xcc -I` compiles (#219).
            // The .exe is named after the SwiftPM target, resolved from
            // the package rather than guessed from the display `name`.
            let resolvedExe = await ExecutableNameResolver.resolve(projectRoot: projectRoot, manifest: manifest)
            let exeName = resolvedExe + ".exe"
            let buildDir = projectRoot.appendingPathComponent(".build")
            if alreadyBuilt,
               Self.builtBinary(exeName: exeName, buildDir: buildDir, configuration: configuration) != nil
            {
                print("swift-pwa: using the \(configuration.swiftPMValue) build the permission check just made")
            } else {
                let packagePaths = Self.resolvePackagePaths(projectRoot: projectRoot)
                let searchDirs = nativeLibraryDirs + (packagePaths?.libDirs ?? [])
                try await Shell.run(
                    "swift",
                    ["build", "-c", configuration.swiftPMValue]
                        + NativeLibrarySearch.compilerArgs(
                            for: nativeIncludeDirs + (packagePaths?.includeDirs ?? [])
                        )
                        + NativeLibrarySearch.linkerArgs(for: searchDirs, target: .windows),
                    cwd: projectRoot
                )
            }
            guard let binary = Self.builtBinary(exeName: exeName, buildDir: buildDir, configuration: configuration)
            else {
                throw BundlerError.binaryMissing(
                    buildDir.appendingPathComponent(configuration.swiftPMValue).appendingPathComponent(exeName),
                    expectedName: exeName
                )
            }

            let bundleDir = outputDir.appendingPathComponent(manifest.name)
            if FileManager.default.fileExists(atPath: bundleDir.path) {
                try FileManager.default.removeItem(at: bundleDir)
            }
            try FileManager.default.createDirectory(
                at: bundleDir, withIntermediateDirectories: true
            )

            let bundledExe = bundleDir.appendingPathComponent(exeName)
            try FileManager.default.copyItem(at: binary, to: bundledExe)

            // Walked from the exe the build produced, not the copy the
            // resource edits below rewrite.
            let runtimeDLLs = try swiftRuntimeDLLs(for: binary)

            // Any SwiftPM resource bundles the build produced go beside the exe
            // — which on Windows *is* where `Bundle.module` looks, so an app
            // with resource-carrying dependencies works off the build machine.
            try ResourceBundles.stage(
                ResourceBundles.found(in: binary.deletingLastPathComponent()),
                into: bundleDir
            )

            // Embed the Common Controls v6 manifest into the bundled
            // EXE's resource section. The dialog shim's
            // `TaskDialogIndirect` import only exists in comctl32 v6;
            // without an SxS manifest, the loader resolves it against
            // v5 (which stubs the symbol by ordinal but doesn't
            // implement it) and surfaces "Ordinal 345 could not be
            // located" at process start. We embed the manifest here
            // rather than via `#pragma comment(linker, "/manifestdependency:...")`
            // in the C++ shim because lld-link (Swift-on-Windows uses
            // clang-cl + lld-link, not link.exe) silently drops that
            // pragma. The resulting EXE has no resource section, and
            // the manifest never makes it in.
            try embedComCtl6Manifest(at: bundledExe)

            // Flip the EXE to the WINDOWS subsystem so double-clicking it in
            // Explorer doesn't spawn a console window next to the app's own
            // window. (See suppressConsoleWindow for the why.)
            try await suppressConsoleWindow(at: bundledExe)

            // App icon: inject an RT_GROUP_ICON/RT_ICON from pwa.json's PNG
            // into the EXE's resource section.
            await IconOutcome.report(embedPortableIcon(at: bundledExe))

            // Name and version, where Windows keeps them. Also what the
            // runtime reads `app.name` from, so it can't be best-effort like
            // the icon: without it `app.documentsDir` is named after the
            // executable.
            try WindowsResources.update(bundledExe, with: [.init(
                type: WindowsResources.rtVersion,
                id: 1,
                data: WindowsVersionInfo.build(name: manifest.name, version: manifest.version, exeName: exeName)
            )])

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

            let runtimeBytes = try SwiftRuntimeStaging.copy(runtimeDLLs, into: bundleDir)
            if !runtimeDLLs.isEmpty {
                print(String(
                    format: "swift-pwa: staged the Swift runtime next to the app (%d DLLs, %.1f MB)",
                    runtimeDLLs.count, Double(runtimeBytes) / 1_048_576
                ))
            }

            // Stage onnxruntime.dll next to the exe so the segmentation
            // backend's shared-lib dependency resolves at launch.
            try await stageOnnxRuntimeDLLIfNeeded(nextTo: bundleDir)
            try stageDeclaredNativeLibraries(nextTo: bundleDir)

            if bootstrapWebView2 {
                try await downloadBootstrapper(into: bundleDir)
            }

            switch packageFormat {
            case .portable:
                // MSIX declares file associations in its manifest; the portable
                // folder has no installer, so it ships opt-in registration scripts.
                try writeFileAssociationScripts(into: bundleDir, exeName: exeName)
                try writeURLSchemeScripts(into: bundleDir, exeName: exeName)
                return bundleDir
            case .msix:
                return try await buildMSIX(stagingDir: bundleDir)
            }
        #endif
    }

    /// Emit `register-file-types.cmd` / `unregister-file-types.cmd` into `dir`
    /// when `windows.document_types` declares any. A portable app has no
    /// installer, so these opt-in scripts write the per-user
    /// `HKCU\Software\Classes` association pointing at the exe *at its current
    /// location* (`%~dp0`). No-op when no types are declared.
    func writeFileAssociationScripts(into dir: URL, exeName: String) throws {
        guard let scripts = FileAssociationSupport.registrationScripts(
            docTypes: manifest.windows?.documentTypes ?? [],
            exeName: exeName,
            appID: manifest.id,
            appName: manifest.name
        ) else { return }
        // Batch files want CRLF line endings.
        try scripts.register.joined(separator: "\r\n")
            .write(to: dir.appendingPathComponent("register-file-types.cmd"), atomically: true, encoding: .utf8)
        try scripts.unregister.joined(separator: "\r\n")
            .write(to: dir.appendingPathComponent("unregister-file-types.cmd"), atomically: true, encoding: .utf8)
        print("swift-pwa: wrote register-file-types.cmd (\(scripts.register.count) lines) for file associations")
    }

    /// Emit `register-url-schemes.cmd` / `unregister-url-schemes.cmd` into
    /// `dir` when `url_schemes` declares any — the deep-link counterpart to
    /// ``writeFileAssociationScripts(into:exeName:)``, and a separate pair of
    /// files because they are a separate decision: an app can want one kind of
    /// association and not the other, and a user who runs only one script
    /// should get only what they asked for. No-op when nothing is declared.
    func writeURLSchemeScripts(into dir: URL, exeName: String) throws {
        guard let scripts = URLSchemeSupport.registrationScripts(
            schemes: manifest.urlSchemes ?? [],
            exeName: exeName,
            appName: manifest.name
        ) else { return }
        // Batch files want CRLF line endings.
        try scripts.register.joined(separator: "\r\n")
            .write(to: dir.appendingPathComponent("register-url-schemes.cmd"), atomically: true, encoding: .utf8)
        try scripts.unregister.joined(separator: "\r\n")
            .write(to: dir.appendingPathComponent("unregister-url-schemes.cmd"), atomically: true, encoding: .utf8)
        print("swift-pwa: wrote register-url-schemes.cmd (\(scripts.register.count) lines) for URL schemes")
    }

    /// Stage the ONNX Runtime runtime DLLs into `dir` when the tier is on. The
    /// segmentation backend links ONNX Runtime as a *shared* lib, so its DLL(s)
    /// must be resolvable at launch — Windows searches the exe's own directory
    /// first. The same files the link-time gate put on `LIB` (an
    /// idempotent/cached resolve).
    ///
    /// - `ai.onnx_gpu` (DirectML) stages `onnxruntime.dll` (the DirectML build,
    ///   which retains the CPU EP for fallback), the shared-provider bridge
    ///   `onnxruntime_providers_shared.dll`, and `DirectML.dll`. DirectML ships
    ///   in-box on Windows 10+, so there's no CUDA-style external dependency.
    /// - `ai.local_onnx_runtime` (CPU) stages just `onnxruntime.dll`.
    private func stageOnnxRuntimeDLLIfNeeded(nextTo dir: URL) async throws {
        let dlls: [String]
        let libDir: URL
        let reason: String
        if manifest.ai?.onnxGpu == true {
            libDir = try await OnnxRuntimeWindowsDirectMLArtifact.ensureLibDir(projectRoot: projectRoot)
            dlls = ["onnxruntime.dll", "onnxruntime_providers_shared.dll", "DirectML.dll"]
            reason = "ai.onnx_gpu"
        } else if OnnxRuntimeTier.isEnabled(manifest: manifest, projectRoot: projectRoot) {
            libDir = try await OnnxRuntimeWindowsArtifact.ensureLibDir(projectRoot: projectRoot)
            dlls = ["onnxruntime.dll"]
            reason = "on-device ONNX Runtime tier"
        } else {
            return
        }
        for dll in dlls {
            let src = libDir.appendingPathComponent(dll)
            let dest = dir.appendingPathComponent(dll)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: src, to: dest)
        }
        print("swift-pwa: staged \(dlls.joined(separator: ", ")) next to the app (\(reason))")
    }

    /// The Swift runtime DLLs `binary` needs, from the toolchain it was built
    /// with. See ``SwiftRuntimeStaging``.
    private func swiftRuntimeDLLs(for binary: URL) throws -> [URL] {
        // Windows spells it `Path`, and compares the two spellings equal.
        let path = ProcessInfo.processInfo.environment
            .first { $0.key.caseInsensitiveCompare("PATH") == .orderedSame }?.value
        guard let runtimeDir = SwiftRuntimeStaging.runtimeDirectory(path: path) else {
            print("""
            swift-pwa: warning — swiftCore.dll isn't on PATH, so the Swift runtime can't be staged, \
            and the bundle will start only where a Swift toolchain is on PATH.
            """)
            return []
        }
        return try SwiftRuntimeStaging.closure(
            of: binary, searchDirs: [runtimeDir, binary.deletingLastPathComponent()]
        )
    }

    /// Copy the app's own vendored DLLs (`windows.native_library_dirs`) next to
    /// the exe, which is where Windows' loader looks first. Without this the
    /// build links cleanly against the import lib and the app dies at launch on
    /// the user's machine with a missing-DLL dialog naming no fix.
    private func stageDeclaredNativeLibraries(nextTo dir: URL) throws {
        for src in try NativeLibrarySearch.declaredDirs(
            manifest: manifest, target: .windows, projectRoot: projectRoot
        ).flatMap({ NativeLibrarySearch.stageableLibraries(in: $0, target: .windows) }) {
            let dest = dir.appendingPathComponent(src.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: src, to: dest)
            print("swift-pwa: staged \(src.lastPathComponent) next to the app (windows.native_library_dirs)")
        }
    }

    // MARK: - swift-pwa NuGet packages auto-detect

    /// Walk likely locations to find the swift-pwa repo's `packages/`
    /// folder (where `nuget install` drops `Microsoft.Web.WebView2`
    /// and `Microsoft.Windows.ImplementationLibrary` headers + libs).
    /// If we find them, return the header directories and the loader's
    /// import-library directory, which the caller passes to `swift build` as
    /// `-Xcc -I` / `-Xlinker /LIBPATH:` — so users no longer have to re-export
    /// INCLUDE and LIB in every fresh PowerShell session.
    ///
    /// Flags rather than those two environment variables because Swift 6.4's
    /// `swiftbuild` engine passes neither to the tasks that need them (#219).
    ///
    /// Returns `nil` (no override) on non-Windows hosts and on hosts
    /// where we can't locate the packages — falls through to inherited
    /// env, and `clang-cl` will surface the same `'wil/com.h' file
    /// not found` error as before, which is at least directly
    /// actionable.
    ///
    /// Search order (covers the two common dependency layouts):
    ///
    ///   1. `<projectRoot>/packages/...` — projectRoot *is* swift-pwa
    ///   2. `<projectRoot>/../packages/...` — Examples/HelloPWA case
    ///   3. `<projectRoot>/../../packages/...`
    ///   4. `<projectRoot>/.build/checkouts/swift-pwa/packages/...`
    ///      — when swift-pwa was pulled as a git dependency
    ///
    /// We do not try to drive `Launch-VsDevShell.ps1` ourselves —
    /// reproducing what `vsdevcmd.bat` does is fragile, and most
    /// users are already running inside a VS Developer PowerShell
    /// (or have it on PATH via a different mechanism). If the MSVC
    /// environment is missing entirely, `swift build` fails earlier
    /// with `lld-link: error: could not open 'msvcrt.lib'`, which
    /// the docs cover.
    /// Also called by ``NativeLibrarySearch`` for the CLI's *host* runs — the
    /// headless catalog dump, `dev` and `drive` compile `CWebView2Shim` too,
    /// and until they were given these flags every `swift-pwa build --target
    /// windows` on Swift 6.4 died in the catalog dump with
    /// `'wil/com.h' file not found`, before the bundler below ever ran.
    /// `quiet` suppresses the banner for those callers.
    static func resolvePackagePaths(
        projectRoot: URL, quiet: Bool = false
    ) -> (includeDirs: [URL], libDirs: [URL])? {
        #if !os(Windows)
            return nil
        #else
            let webview2Subpath = "packages/Microsoft.Web.WebView2/build/native"
            let wilSubpath = "packages/Microsoft.Windows.ImplementationLibrary/include"

            let candidates: [URL] = [
                projectRoot,
                projectRoot.deletingLastPathComponent(),
                projectRoot.deletingLastPathComponent().deletingLastPathComponent(),
                projectRoot.appendingPathComponent(".build/checkouts/swift-pwa")
            ]

            guard let swiftPwaRoot = candidates.first(where: {
                let p = $0.appendingPathComponent("\(webview2Subpath)/include/WebView2.h").path
                return FileManager.default.fileExists(atPath: p)
            }) else {
                return nil
            }

            // Architecture for the loader lib subdirectory. The NuGet
            // package ships per-arch loaders under `build/native/{x86,
            // x64,arm64}`; pick the one matching the host's Swift
            // toolchain since we don't cross-compile.
            #if arch(arm64)
                let arch = "arm64"
            #else
                let arch = "x64"
            #endif

            let webview2IncludePath = swiftPwaRoot
                .appendingPathComponent("\(webview2Subpath)/include").path
            let wilIncludePath = swiftPwaRoot
                .appendingPathComponent(wilSubpath).path
            let webview2LibPath = swiftPwaRoot
                .appendingPathComponent("\(webview2Subpath)/\(arch)").path

            if !quiet {
                print("""
                swift-pwa: using the swift-pwa NuGet packages
                  WebView2: \(webview2IncludePath)
                  WIL:      \(wilIncludePath)
                  Loader:   \(webview2LibPath)
                """)
            }

            return (
                [URL(fileURLWithPath: webview2IncludePath), URL(fileURLWithPath: wilIncludePath)],
                [URL(fileURLWithPath: webview2LibPath)]
            )
        #endif
    }

    // MARK: - Common Controls v6 manifest embed

    /// Embed the `Microsoft.Windows.Common-Controls` v6 manifest
    /// dependency into the EXE's resource section, as `RT_MANIFEST` id 1
    /// (`CREATEPROCESS_MANIFEST_RESOURCE_ID`, the one Windows reads at process
    /// start). Runs after `swift build` and the bundle copy — the `.exe`
    /// SwiftPM produced has no resource section, and `lld-link` silently drops
    /// the `/manifestdependency` pragma we'd otherwise embed at link time.
    ///
    /// Through `WindowsResources` rather than `mt.exe`: the same kernel32 API,
    /// so no Windows SDK tool on `PATH` — without one the manifest used to be
    /// skipped with a warning — and the COFF symbol table `mt.exe` dropped is
    /// carried across (#276).
    private func embedComCtl6Manifest(at exe: URL) throws {
        let manifestXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
          <dependency>
            <dependentAssembly>
              <assemblyIdentity
                type="win32"
                name="Microsoft.Windows.Common-Controls"
                version="6.0.0.0"
                processorArchitecture="*"
                publicKeyToken="6595b64144ccf1df"
                language="*"
              />
            </dependentAssembly>
          </dependency>
        </assembly>
        """
        try WindowsResources.update(exe, with: [.init(
            type: WindowsResources.rtManifest, id: 1, data: Data(manifestXML.utf8)
        )])
    }

    // MARK: - Console-window suppression

    /// Flip the bundled EXE to the **WINDOWS** subsystem so launching it from
    /// Explorer doesn't open a console window alongside the app's own window.
    ///
    /// SwiftPM links executables as the **CONSOLE** subsystem (a Swift `@main`
    /// program enters through the C runtime's `main`, the console startup
    /// path). Windows allocates a console for a console-subsystem EXE launched
    /// from Explorer, so the user sees a stray terminal next to the WebView2
    /// window. `editbin /SUBSYSTEM:WINDOWS` rewrites only the PE subsystem
    /// field; the entry point stays `mainCRTStartup`, so Swift's `main` still
    /// runs — no `WinMain` shim and no `unsafeFlags` in the user's package.
    ///
    /// Trade-off: with the WINDOWS subsystem, `print` / stderr go nowhere when
    /// the app is launched from Explorer (correct for a shipped GUI app);
    /// developers still get logs via `swift run` during iteration.
    ///
    /// `editbin.exe` ships with the MSVC toolset and is on PATH inside a Visual
    /// Studio Developer shell (same as `mt.exe`). If it's missing we warn and
    /// leave the console-subsystem EXE as-is rather than failing the build.
    private func suppressConsoleWindow(at exe: URL) async throws {
        do {
            try await Shell.run("editbin.exe", ["/SUBSYSTEM:WINDOWS", exe.path])
        } catch BundlerError.toolMissing {
            FileHandle.standardError.write(Data("""
            swift-pwa: warning — editbin.exe not found on PATH; the bundled app \
            keeps the console subsystem, so launching it from Explorer opens a \
            console window next to the app. Run from inside a Visual Studio \
            Developer Shell (which puts editbin on PATH) to suppress it.

            """.utf8))
        }
    }

    // MARK: - App icon

    /// Embed `pwa.json`'s `icon` (a PNG) into the portable `.exe` so it
    /// shows a real icon in Explorer / the taskbar / Alt-Tab instead of the
    /// default Windows application icon — the one platform whose icon
    /// pipeline used to stop at the MSIX tile. Best-effort and reported (not
    /// thrown): a missing / non-PNG / unreadable icon leaves the default
    /// icon and never fails the build, matching every other bundler's icon
    /// step. See `WindowsIcon` for the resource-injection mechanics.
    private func embedPortableIcon(at exe: URL) async -> IconOutcome {
        guard let icon = manifest.icon(for: .windows) else { return .noneSet }
        let src = projectRoot.appendingPathComponent(icon)
        guard src.pathExtension.lowercased() == "png" else {
            return .notPNG(source: icon, placeholder: false)
        }
        guard let pngData = try? Data(contentsOf: src) else {
            return .notFound(source: icon, placeholder: false)
        }
        guard let (width, height) = PNGDimensions.read(pngData) else {
            // Extension says PNG but the bytes don't parse — treat as
            // not-a-PNG rather than claiming success.
            return .notPNG(source: icon, placeholder: false)
        }
        // Pre-render the small shell sizes (16/32/48) alongside the source so
        // the taskbar / Explorer small-icon view stay crisp instead of the
        // shell down-sampling the one big image. `buildImages` down-renders
        // only the sizes smaller than the source, embedding the source itself
        // verbatim for the largest slot.
        let images = WindowsIcon.buildImages(source: pngData, width: width, height: height)
        let groupDir = WindowsIcon.groupIconDirectory(images: images)
        do {
            try WindowsIcon.embed(
                images: images, groupDirectory: groupDir, groupID: WindowsIcon.groupID, into: exe
            )
            let sizes = images.map { "\($0.width)" }.joined(separator: "/")
            return .bundled(source: icon, detail: "\(width)×\(height) → \(sizes) px")
        } catch {
            return .toolFailed(source: icon, reason: "\(error)")
        }
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
    /// `AppxManifest.xml`, and a `Square150x150Logo.png` icon — plus, for an
    /// icon with dark art, theme-qualified taskbar logos and the
    /// `resources.pri` that lets Windows pick between them.
    ///
    /// The MSIX format requires a signed package for the OS to install
    /// it without developer-mode sideloading; we don't try to generate
    /// a self-signed cert on the fly (pwsh's `New-SelfSignedCertificate`
    /// is the documented path), so unsigned packages here are valid
    /// only on developer-mode boxes.
    private func buildMSIX(stagingDir: URL) async throws -> URL {
        // The MSIX schema requires at least a Square150x150Logo. If the
        // caller provided an icon, copy it; otherwise emit a 1x1
        // placeholder PNG so makeappx doesn't reject the manifest.
        let logoPath = stagingDir.appendingPathComponent("Square150x150Logo.png")
        var iconOutcome: IconOutcome
        let art = manifest.iconArt(for: .windows)
        if let icon = art?.light {
            let src = projectRoot.appendingPathComponent(icon)
            let isPNG = src.pathExtension.lowercased() == "png"
            if isPNG, FileManager.default.fileExists(atPath: src.path) {
                try FileManager.default.copyItem(at: src, to: logoPath)
                iconOutcome = .bundled(source: icon, detail: nil)
            } else {
                iconOutcome = isPNG
                    ? .notFound(source: icon, placeholder: true)
                    : .notPNG(source: icon, placeholder: true)
            }
        } else {
            iconOutcome = .noneSet
        }
        if !FileManager.default.fileExists(atPath: logoPath.path) {
            try Data(placeholderPNG).write(to: logoPath)
        }

        // Dark art → a taskbar logo per taskbar theme. Windows has no tinted
        // mode, so that art isn't used here.
        var themedLogos = false
        if case let .bundled(source, _) = iconOutcome, let art, art.dark != nil {
            if let problem = art.problem(under: projectRoot) {
                iconOutcome = .bundled(source: source, detail: "dark taskbar logo skipped: \(problem.line)")
            } else if try stageThemedTaskbarLogos(art, into: stagingDir) {
                themedLogos = true
            } else {
                iconOutcome = .bundled(
                    source: source, detail: "dark taskbar logo skipped: this host can't resize PNGs"
                )
            }
        }

        /// Generate AppxManifest.xml. The architecture written into
        /// `<Identity ProcessorArchitecture="…">` must match the EXE
        /// SwiftPM produced — when the host's Swift toolchain is x86_64
        /// and the user passed `--arch arm64` (or vice versa),
        /// `Add-AppxPackage` rejects the install with a "doesn't match
        /// current device" error. We don't try to detect that mismatch
        /// here because cross-compile on Swift-for-Windows is still
        /// rough; instead, document the constraint in
        /// `docs/windows-setup.md`.
        func writeAppxManifest(themed: Bool) throws {
            try AppxManifestGenerator.render(
                manifest: manifest, arch: arch,
                square44x44Logo: themed ? Self.themedTaskbarLogo : "Square150x150Logo.png"
            ).write(to: stagingDir.appendingPathComponent("AppxManifest.xml"), atomically: true, encoding: .utf8)
        }
        try writeAppxManifest(themed: themedLogos)
        if themedLogos {
            do {
                try await indexPackageResources(stagingDir: stagingDir)
                iconOutcome = .bundled(source: art?.light ?? "", detail: "light + dark taskbar logos")
            } catch {
                // Without the index the qualified files resolve to nothing,
                // so fall back to the one logo every build has.
                try removeThemedTaskbarLogos(from: stagingDir)
                try writeAppxManifest(themed: false)
                iconOutcome = .bundled(
                    source: art?.light ?? "",
                    detail: "dark taskbar logo skipped: makepri failed (\(error))"
                )
            }
        }
        IconOutcome.report(iconOutcome)

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

    /// What `Square44x44Logo` names when the themed set is staged.
    static let themedTaskbarLogo = "Square44x44Logo.png"

    /// The `targetsize` qualifiers staged: the sizes the taskbar, Start and
    /// the shell ask for at 100 % scale, up to the jumbo view.
    static let taskbarLogoSizes = [16, 24, 32, 48, 256]

    /// Stage the taskbar logo per taskbar theme: the dark art as
    /// `altform-unplated` (what a dark taskbar shows) and the light art as
    /// `altform-lightunplated` (a light taskbar), measured on Windows 11 to
    /// switch live with the theme, plus the light art unqualified and as the
    /// plain `targetsize` fallback. Returns `false`, having written nothing,
    /// where PNGs can't be resized here.
    private func stageThemedTaskbarLogos(_ art: PWAManifest.IconArt, into stagingDir: URL) throws -> Bool {
        guard let darkPath = art.dark else { return false }
        let light = try Data(contentsOf: projectRoot.appendingPathComponent(art.light))
        let dark = try Data(contentsOf: projectRoot.appendingPathComponent(darkPath))
        var files: [(String, Data)] = []
        guard let base = WindowsIcon.resizePNG(light, to: 44) else { return false }
        files.append((Self.themedTaskbarLogo, base))
        for size in Self.taskbarLogoSizes {
            guard let lightSized = WindowsIcon.resizePNG(light, to: size),
                  let darkSized = WindowsIcon.resizePNG(dark, to: size)
            else { return false }
            files.append(("Square44x44Logo.targetsize-\(size).png", lightSized))
            files.append(("Square44x44Logo.targetsize-\(size)_altform-unplated.png", darkSized))
            files.append(("Square44x44Logo.targetsize-\(size)_altform-lightunplated.png", lightSized))
        }
        for (name, data) in files {
            try data.write(to: stagingDir.appendingPathComponent(name))
        }
        return true
    }

    private func removeThemedTaskbarLogos(from stagingDir: URL) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: stagingDir.path) where name.hasPrefix("Square44x44Logo") {
            try fm.removeItem(at: stagingDir.appendingPathComponent(name))
        }
    }

    /// Write `resources.pri`, the index Windows resolves qualified assets
    /// through; without it a `targetsize` / `altform` file is never chosen.
    /// `makepri.exe` ships in the Windows SDK beside `makeappx.exe`. Its
    /// config goes outside the staging tree so it isn't packed.
    private func indexPackageResources(stagingDir: URL) async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("swift-pwa-pri-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let config = tmp.appendingPathComponent("priconfig.xml")
        try await Shell.run("makepri.exe", ["createconfig", "/cf", config.path, "/dq", "en-US", "/o"])
        try await Shell.run("makepri.exe", [
            "new", "/pr", stagingDir.path, "/cf", config.path,
            "/mn", stagingDir.appendingPathComponent("AppxManifest.xml").path,
            "/of", stagingDir.appendingPathComponent("resources.pri").path, "/o"
        ])
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
