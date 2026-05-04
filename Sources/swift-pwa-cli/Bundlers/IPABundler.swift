import ArgumentParser
import Foundation

/// Builds an iOS `.app` (simulator) or `.ipa` (device).
///
/// Uses `xcodebuild` rather than `swift build --triple` because Apple
/// does not ship an iOS Swift SDK that SwiftPM can cross-compile against
/// directly — the manifest needs to compile for the host (macOS) while
/// targets compile for iOS, and only Xcode handles that split cleanly.
///
/// Prerequisites:
///   - Xcode 16+ with the iOS Simulator platform installed.
///   - For `--simulator`: an iOS Simulator runtime matching the SDK
///     installed via `Xcode > Settings > Platforms`.
///   - For device: a provisioning profile and `--sign <identity>`.
struct IPABundler {
    let manifest: PWAManifest
    let projectRoot: URL
    let outputDir: URL
    let signIdentity: String?
    let simulator: Bool

    func build() async throws -> URL {
        let derived = outputDir.appendingPathComponent("ios-derived")
        let destination = simulator
            ? "generic/platform=iOS Simulator"
            : "generic/platform=iOS"
        let configuration = "Release"

        var args = [
            "xcodebuild",
            "-scheme", manifest.name,
            "-workspace", projectRoot.path,
            "-destination", destination,
            "-configuration", configuration,
            "-derivedDataPath", derived.path
        ]
        if simulator {
            args.append(contentsOf: [
                "CODE_SIGNING_REQUIRED=NO",
                "CODE_SIGNING_ALLOWED=NO"
            ])
        } else if let identity = signIdentity {
            args.append("CODE_SIGN_IDENTITY=\(identity)")
        }
        args.append("build")

        try await Shell.run("/usr/bin/env", args)

        // SwiftPM executable targets compile to a bare Mach-O, not an .app —
        // xcodebuild puts it (plus any SwiftPM resource bundles) in:
        //   <derived>/Build/Products/<Configuration>-iphonesimulator/
        // We assemble the .app ourselves from those pieces.
        let suffix = simulator ? "iphonesimulator" : "iphoneos"
        let productsDir = derived
            .appendingPathComponent("Build/Products")
            .appendingPathComponent("\(configuration)-\(suffix)")
        let binary = productsDir.appendingPathComponent(manifest.name)
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw BundlerError.binaryMissing(binary)
        }

        let app = try assembleApp(binary: binary, productsDir: productsDir)

        if simulator {
            // Adhoc-sign so the simulator will accept it.
            try await Shell.run("/usr/bin/env", ["codesign", "--force", "--sign", "-", app.path])
            print("""
            note: install + launch with:
              xcrun simctl boot "iPhone 16" 2>/dev/null || true
              xcrun simctl install booted "\(app.path)"
              xcrun simctl launch booted \(manifest.ios?.bundleIdentifier ?? manifest.id)
            """)
            return app
        }

        // Device build: codesign, then assemble Payload/ → .ipa.
        if let identity = signIdentity {
            try await Shell.run("/usr/bin/env", ["codesign", "--force", "--sign", identity, app.path])
        } else {
            print("note: not signed. Pass --sign <identity> for an installable build.")
        }
        let payload = outputDir.appendingPathComponent("Payload")
        if FileManager.default.fileExists(atPath: payload.path) {
            try FileManager.default.removeItem(at: payload)
        }
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: app,
            to: payload.appendingPathComponent("\(manifest.name).app")
        )
        let ipa = outputDir.appendingPathComponent("\(manifest.name).ipa")
        if FileManager.default.fileExists(atPath: ipa.path) {
            try FileManager.default.removeItem(at: ipa)
        }
        try await Shell.run("/usr/bin/env", ["zip", "-r", ipa.path, "Payload"], cwd: outputDir)
        return ipa
    }

    /// Lay out the `.app` from xcodebuild's loose products: copy the binary,
    /// the SwiftPM resource bundles (e.g. `bridge.js`), the project's `web/`
    /// directory, and write `Info.plist`. iOS bundles are flat — no
    /// `Contents/MacOS` wrapper.
    private func assembleApp(binary: URL, productsDir: URL) throws -> URL {
        let fm = FileManager.default
        let app = outputDir.appendingPathComponent("\(manifest.name).app")
        if fm.fileExists(atPath: app.path) {
            try fm.removeItem(at: app)
        }
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        try fm.copyItem(at: binary, to: app.appendingPathComponent(manifest.name))

        try InfoPlistGenerator.iOS(manifest: manifest)
            .write(to: app.appendingPathComponent("Info.plist"))

        // SwiftPM resource bundles (e.g. swift-pwa_SwiftPWACore.bundle holding bridge.js).
        for entry in (try? fm.contentsOfDirectory(atPath: productsDir.path)) ?? []
            where entry.hasSuffix(".bundle")
        {
            try fm.copyItem(
                at: productsDir.appendingPathComponent(entry),
                to: app.appendingPathComponent(entry)
            )
        }

        // Project's web/ directory.
        let webSrc = projectRoot.appendingPathComponent(manifest.web.directory)
        if fm.fileExists(atPath: webSrc.path) {
            try fm.copyItem(at: webSrc, to: app.appendingPathComponent("web"))
        }
        return app
    }
}
