import ArgumentParser
import Foundation

/// Builds an AppImage on Linux. Requires `linuxdeploy` (and the AppImage
/// plugin) on PATH. Errors out with an install hint if missing.
struct AppImageBundler {
    let manifest: PWAManifest
    let projectRoot: URL
    let outputDir: URL
    var configuration: BuildConfiguration = .release
    /// Directories holding vendored native libraries this build links against
    /// — the llama.cpp / ONNX Runtime tiers swift-pwa resolves, plus the app's
    /// own `linux.native_library_dirs`. See ``NativeLibrarySearch``.
    var nativeLibraryDirs: [URL] = []

    func build() async throws -> URL {
        // 1. swift build.
        // Note: `--static-swift-stdlib` was dropped — recent Swift
        // toolchains (6.0+) ship without a bundled static stdlib on
        // Linux, and the flag silently extends build time without an
        // effect. linuxdeploy bundles the dynamic Swift runtime libs
        // alongside the binary, which is what we actually want.
        try await Shell.run(
            "/usr/bin/env",
            ["swift", "build", "-c", configuration.swiftPMValue]
                + NativeLibrarySearch.linkerArgs(for: nativeLibraryDirs, target: .linux),
            cwd: projectRoot
        )
        // SwiftPM target / product name, resolved from the package
        // rather than guessed from the display `name`.
        let resolvedExe = await ExecutableNameResolver.resolve(projectRoot: projectRoot, manifest: manifest)
        let binDir = projectRoot
            .appendingPathComponent(".build")
            .appendingPathComponent(configuration.swiftPMValue)
        let binary = binDir.appendingPathComponent(resolvedExe)
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw BundlerError.binaryMissing(binary, expectedName: resolvedExe)
        }

        // 2. Lay out an AppDir.
        let appDir = outputDir.appendingPathComponent("\(manifest.name).AppDir")
        if FileManager.default.fileExists(atPath: appDir.path) {
            try FileManager.default.removeItem(at: appDir)
        }
        try FileManager.default.createDirectory(
            at: appDir.appendingPathComponent("usr/bin"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: appDir.appendingPathComponent("usr/share/applications"),
            withIntermediateDirectories: true
        )

        // `linux.executable_name` wins for the Linux backend specifically;
        // otherwise use the resolved SwiftPM product name.
        let exeName = manifest.linux?.executableName ?? resolvedExe
        let installedBin = appDir.appendingPathComponent("usr/bin/\(exeName)")
        try FileManager.default.copyItem(at: binary, to: installedBin)

        // Any SwiftPM resource bundles the build produced go beside the binary —
        // which on Linux *is* where `Bundle.module` looks, so an app with
        // resource-carrying dependencies works off the build machine.
        try ResourceBundles.stage(
            ResourceBundles.found(in: binDir),
            into: installedBin.deletingLastPathComponent()
        )

        // Icon: linuxdeploy requires the file referenced by `Icon=` in
        // `.desktop` to exist at `<AppDir>/<exeName>.png` (or another
        // recognised extension). If the manifest provides a PNG we
        // copy it; otherwise write a 1×1 transparent placeholder so
        // linuxdeploy doesn't fail with `Could not find icon executable`
        // and hang on its retry/prompt path.
        let iconDst = appDir.appendingPathComponent("\(exeName).png")
        let iconOutcome: IconOutcome
        if let icon = manifest.icon(for: .linux) {
            let src = projectRoot.appendingPathComponent(icon)
            let isPNG = src.pathExtension.lowercased() == "png"
            let exists = FileManager.default.fileExists(atPath: src.path)
            if isPNG, exists {
                try FileManager.default.copyItem(at: src, to: iconDst)
                iconOutcome = .bundled(source: icon, detail: nil)
            } else {
                try writePlaceholderIcon(to: iconDst)
                iconOutcome = isPNG
                    ? .notFound(source: icon, placeholder: true)
                    : .notPNG(source: icon, placeholder: true)
            }
        } else {
            try writePlaceholderIcon(to: iconDst)
            iconOutcome = .noneSet
        }
        IconOutcome.report(iconOutcome)

        // .desktop
        let desktop = Self.desktopEntry(manifest: manifest, exeName: exeName)
        try desktop.write(
            to: appDir.appendingPathComponent("usr/share/applications/\(exeName).desktop"),
            atomically: true,
            encoding: .utf8
        )

        // Web bundle **beside the binary** — `usr/bin/web`, which is where
        // `WindowContent.bundledWeb` looks off Apple (`Bundle.main.resourceURL`
        // for a bare ELF binary is its own directory). It used to go to
        // `usr/share/<exe>/web`, a location nothing resolves: a scaffolded app's
        // AppImage died in `configure` with "couldn't find the app's web/
        // directory", and only the in-tree examples ran, because they declare
        // `resources: [.copy("web")]` and fall back to their own resource bundle.
        let webSrc = projectRoot.appendingPathComponent(manifest.web.directory)
        if FileManager.default.fileExists(atPath: webSrc.path) {
            try FileManager.default.copyItem(
                at: webSrc,
                to: installedBin.deletingLastPathComponent().appendingPathComponent("web")
            )
        }

        // 3. Run linuxdeploy. Pass icon and desktop files explicitly
        // so linuxdeploy doesn't have to discover them (and doesn't
        // fall through to its interactive prompt path on missing data,
        // which can look like a hang under inherited stdio).
        let linuxdeploy = try await Self.findOrThrow("linuxdeploy")
        let desktopPath = appDir.appendingPathComponent("usr/share/applications/\(exeName).desktop").path
        let iconPath = iconDst.path
        var args = [
            linuxdeploy.lastPathComponent,
            "--appdir", appDir.path,
            "--desktop-file", desktopPath,
            "--icon-file", iconPath
        ]
        // ai.local_onnx_runtime links ONNX Runtime as a *shared* lib
        // (libonnxruntime.so), which isn't a NEEDED entry linuxdeploy can find
        // on a system path — so hand it to linuxdeploy explicitly with
        // `--library`. linuxdeploy copies it into the AppDir's usr/lib and
        // patches the rpath, so the app resolves it at runtime. (The same
        // idempotent resolve the link-time gate used — see OnnxRuntimeLinuxArtifact.)
        if manifest.ai?.onnxGpu == true {
            // GPU (CUDA 12) build: three shared libs — the runtime plus the
            // out-of-tree provider libs the runtime dlopens when the CUDA EP is
            // appended. All must land under their SONAME name in usr/lib. (The
            // CUDA runtime + cuDNN are NOT bundled — expected on the target; a
            // missing/mismatched runtime makes the CUDA EP fail to load, which
            // OrtModelSession turns into a transparent CPU fallback.)
            let libDir = try await OnnxRuntimeLinuxGpuArtifact.ensureLibDir(projectRoot: projectRoot)
            for lib in ["libonnxruntime.so.1"] + OnnxRuntimeLinuxGpuArtifact.providerNames {
                args += ["--library", libDir.appendingPathComponent(lib).path]
            }
            print("swift-pwa: bundling ONNX Runtime CUDA libs into the AppImage (ai.onnx_gpu)")
        } else if OnnxRuntimeTier.isEnabled(manifest: manifest, projectRoot: projectRoot) {
            let libDir = try await OnnxRuntimeLinuxArtifact.ensureLibDir(projectRoot: projectRoot)
            // Deploy the SONAME'd file (`libonnxruntime.so.1`) — that's the
            // name the binary's NEEDED entry references, so linuxdeploy must
            // land it under exactly that filename in the AppDir's usr/lib.
            args += ["--library", libDir.appendingPathComponent("libonnxruntime.so.1").path]
            print("swift-pwa: bundling libonnxruntime.so.1 into the AppImage (on-device ONNX Runtime tier)")
        }
        // The app's own vendored libraries go in the same way, and for the same
        // reason: they exist on no system path on the user's machine either, so
        // an AppImage without them links clean here and dies at launch there.
        let declaredLibDirs = try NativeLibrarySearch.declaredDirs(
            manifest: manifest, target: .linux, projectRoot: projectRoot
        )
        for dir in declaredLibDirs {
            let libs = NativeLibrarySearch.stageableLibraries(in: dir, target: .linux)
            for lib in libs { args += ["--library", lib.path] }
            let noun = libs.count == 1 ? "library" : "libraries"
            print(
                "swift-pwa: bundling \(libs.count) native \(noun) from \(dir.path) "
                    + "into the AppImage (linux.native_library_dirs)"
            )
        }
        args += ["--output", "appimage"]
        // `linuxdeploy` and its plugins are themselves AppImages, and by default
        // each one self-mounts over FUSE. That path **never returns here**: the
        // AppImage finishes its work — the `.AppImage` is complete and correct on
        // disk — and then `build --target linux` sits there forever, our direct
        // child an unreaped zombie while the runtime's mount daemon lingers.
        // Measured on a clean box with the shipped v0.9.11 binary: still waiting
        // at 84 minutes. Extract-and-run skips FUSE entirely, and the same build
        // completes in **26 seconds** — so this isn't a workaround with a cost,
        // it's faster as well. It's also the mode AppImage documents for
        // automation, where FUSE often isn't available at all.
        // linuxdeploy walks the binary's `DT_NEEDED` list before it looks at
        // `--library`, and resolves each entry against the system search path —
        // so a vendored library that lives nowhere on it stops the deploy with
        // `Could not find dependency: libfoo.so`, even though we were about to
        // hand it that exact file. Measured on a real AppImage build. Putting
        // the directories on LD_LIBRARY_PATH is how linuxdeploy documents
        // pointing its resolver at a library tree of your own.
        var deployEnv = ["APPIMAGE_EXTRACT_AND_RUN": "1"]
        if !declaredLibDirs.isEmpty {
            let existing = ProcessInfo.processInfo.environment["LD_LIBRARY_PATH"]
            let paths = declaredLibDirs.map(\.path)
            deployEnv["LD_LIBRARY_PATH"] = (existing.map { paths + [$0] } ?? paths)
                .joined(separator: ":")
        }
        try await Shell.run(
            "/usr/bin/env", args, cwd: outputDir,
            envOverrides: deployEnv
        )

        // linuxdeploy emits <Name>-<arch>.AppImage in cwd.
        let candidates = (try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? []
        let appImage = candidates.first(where: { $0.hasSuffix(".AppImage") })
            .map { outputDir.appendingPathComponent($0) }
        return appImage ?? outputDir
    }

    /// 256×256 transparent PNG written byte-for-byte. Avoids a runtime
    /// dependency on ImageMagick or libpng for the placeholder case.
    private func writePlaceholderIcon(to url: URL) throws {
        // A valid PNG: signature + IHDR (256×256 RGBA) + IDAT (all-transparent,
        // zlib-compressed) + IEND, generated with correct chunk CRCs. 256×256
        // is a standard desktop icon size, and a real PNG matters: linuxdeploy's
        // libpng validates chunk CRCs and aborts on a malformed file (the prior
        // hand-trimmed 1×1 literal had a bad IDAT CRC, failing icon deploy).
        let bytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
            0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x5C, 0x72, 0xA8, 0x66, 0x00, 0x00, 0x01,
            0x15, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0xED, 0xC1, 0x31, 0x01, 0x00,
            0x00, 0x00, 0xC2, 0xA0, 0xF5, 0x4F, 0xED, 0x6B, 0x08, 0xA0, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x78, 0x03, 0x01, 0x3C, 0x00, 0x01, 0xD8, 0x29, 0x43, 0x04, 0x00, 0x00,
            0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
        ]
        try Data(bytes).write(to: url)
    }

    /// Render the `.desktop` entry. Two declarations reach it, both through the
    /// `MimeType=` list — which is how freedesktop expresses *either* kind of
    /// association:
    ///
    /// - `linux.document_types` → the MIME types themselves, plus a `%F` field
    ///   code on `Exec=` so opened file paths arrive as arguments (the runtime
    ///   forwards them to `app.openFile`).
    /// - `url_schemes` → one `x-scheme-handler/<scheme>` pseudo-MIME per
    ///   scheme, which is how a desktop environment records a URL handler, plus
    ///   `%U` so the URL arrives as an argument (→ `app.openURL`).
    ///
    /// **`%U` supersedes `%F` when both are declared**, because a field code is
    /// singular and `%U` is the more general one: it accepts URLs *and* local
    /// paths. The catch is that with `%U` the desktop hands local files over as
    /// `file:///…` URIs rather than bare paths, which is why
    /// ``OpenFile/launchFilePaths(_:)`` accepts a `file:` URL as a path.
    ///
    /// With neither declared the output is unchanged (bare `Exec=`, no
    /// `MimeType=`).
    static func desktopEntry(manifest: PWAManifest, exeName: String) -> String {
        let docMimeTypes = (manifest.linux?.documentTypes ?? [])
            .flatMap(\.mimeTypes)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let schemeMimeTypes = URLSchemeSupport.declared(manifest).map { "x-scheme-handler/\($0)" }
        let mimeTypes = docMimeTypes + schemeMimeTypes
        // freedesktop Exec field codes: `%F` a list of local paths, `%U` a list
        // of URLs. Only added when the app declares something openable, so a
        // launcher-only app's Exec line stays bare.
        let fieldCode = schemeMimeTypes.isEmpty ? (docMimeTypes.isEmpty ? "" : " %F") : " %U"
        var lines = [
            "[Desktop Entry]",
            "Type=Application",
            "Name=\(manifest.name)",
            "Exec=\(exeName)\(fieldCode)",
            "Icon=\(exeName)",
            "Categories=\(manifest.linux?.desktopCategories?.joined(separator: ";") ?? "Utility");",
            "Comment=\(manifest.description ?? manifest.name)",
            "Terminal=false"
        ]
        if !mimeTypes.isEmpty {
            // Trailing `;` is required by the spec for list values.
            lines.append("MimeType=\(mimeTypes.joined(separator: ";"));")
        }
        return lines.joined(separator: "\n")
    }

    private static func findOrThrow(_ name: String) async throws -> URL {
        let path = await (try? Shell.capture("/usr/bin/env", ["which", name]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else {
            throw ValidationError("""
            Required tool not found: \(name).
            Install:
              wget -O linuxdeploy https://github.com/linuxdeploy/linuxdeploy/releases/latest/download/linuxdeploy-x86_64.AppImage
              chmod +x linuxdeploy && sudo mv linuxdeploy /usr/local/bin/
              # plus the appimage plugin: linuxdeploy-plugin-appimage
            """)
        }
        return URL(fileURLWithPath: path)
    }
}
