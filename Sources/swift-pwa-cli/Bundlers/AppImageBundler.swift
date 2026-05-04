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
        let binary = projectRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("release")
            .appendingPathComponent(manifest.name)
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw BundlerError.binaryMissing(binary)
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

        let exeName = manifest.linux?.executableName ?? manifest.name
        let installedBin = appDir.appendingPathComponent("usr/bin/\(exeName)")
        try FileManager.default.copyItem(at: binary, to: installedBin)

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

        // 3. Run linuxdeploy.
        let linuxdeploy = try await Self.findOrThrow("linuxdeploy")
        try await Shell.run("/usr/bin/env", [
            linuxdeploy.lastPathComponent,
            "--appdir", appDir.path,
            "--output", "appimage"
        ], cwd: outputDir)

        // linuxdeploy emits <Name>-<arch>.AppImage in cwd.
        let candidates = (try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? []
        let appImage = candidates.first(where: { $0.hasSuffix(".AppImage") })
            .map { outputDir.appendingPathComponent($0) }
        return appImage ?? outputDir
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
