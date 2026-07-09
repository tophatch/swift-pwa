import ArgumentParser
import Foundation

/// Builds an AppImage on Linux. Requires `linuxdeploy` (and the AppImage
/// plugin) on PATH. Errors out with an install hint if missing.
struct AppImageBundler {
    let manifest: PWAManifest
    let projectRoot: URL
    let outputDir: URL

    func build() async throws -> URL {
        // 1. swift build -c release.
        // Note: `--static-swift-stdlib` was dropped — recent Swift
        // toolchains (6.0+) ship without a bundled static stdlib on
        // Linux, and the flag silently extends build time without an
        // effect. linuxdeploy bundles the dynamic Swift runtime libs
        // alongside the binary, which is what we actually want.
        try await Shell.run(
            "/usr/bin/env",
            ["swift", "build", "-c", "release"],
            cwd: projectRoot
        )
        // SwiftPM target / product name, resolved from the package
        // rather than guessed from the display `name`.
        let resolvedExe = await ExecutableNameResolver.resolve(projectRoot: projectRoot, manifest: manifest)
        let binary = projectRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("release")
            .appendingPathComponent(resolvedExe)
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

        // Icon: linuxdeploy requires the file referenced by `Icon=` in
        // `.desktop` to exist at `<AppDir>/<exeName>.png` (or another
        // recognised extension). If the manifest provides a PNG we
        // copy it; otherwise write a 1×1 transparent placeholder so
        // linuxdeploy doesn't fail with `Could not find icon executable`
        // and hang on its retry/prompt path.
        let iconDst = appDir.appendingPathComponent("\(exeName).png")
        let iconOutcome: IconOutcome
        if let icon = manifest.icon {
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
        let desktop = """
        [Desktop Entry]
        Type=Application
        Name=\(manifest.name)
        Exec=\(exeName)
        Icon=\(exeName)
        Categories=\(manifest.linux?.desktopCategories?.joined(separator: ";") ?? "Utility");
        Comment=\(manifest.description ?? manifest.name)
        Terminal=false
        """
        try desktop.write(
            to: appDir.appendingPathComponent("usr/share/applications/\(exeName).desktop"),
            atomically: true,
            encoding: .utf8
        )

        // Web bundle alongside the binary; the runtime resolves it via
        // an env var or reasonable default. (For MVP, we copy to /usr/share/<exe>/web.)
        let webSrc = projectRoot.appendingPathComponent(manifest.web.directory)
        if FileManager.default.fileExists(atPath: webSrc.path) {
            let webDst = appDir.appendingPathComponent("usr/share/\(exeName)/web")
            try FileManager.default.createDirectory(
                at: webDst.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: webSrc, to: webDst)
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
        if manifest.ai?.localOnnxRuntime == true {
            let libDir = try await OnnxRuntimeLinuxArtifact.ensureLibDir(projectRoot: projectRoot)
            args += ["--library", libDir.appendingPathComponent("libonnxruntime.so").path]
            print("swift-pwa: bundling libonnxruntime.so into the AppImage (ai.local_onnx_runtime)")
        }
        args += ["--output", "appimage"]
        try await Shell.run("/usr/bin/env", args, cwd: outputDir)

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
