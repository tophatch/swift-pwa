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
            "-derivedDataPath", derived.path,
        ]
        if simulator {
            args.append(contentsOf: [
                "CODE_SIGNING_REQUIRED=NO",
                "CODE_SIGNING_ALLOWED=NO",
            ])
        } else if let identity = signIdentity {
            args.append("CODE_SIGN_IDENTITY=\(identity)")
        }
        args.append("build")

        try await Shell.run("/usr/bin/env", args)

        // xcodebuild deposits the .app at:
        //   <derived>/Build/Products/<Configuration>-iphonesimulator/<Name>.app
        // or for device:
        //   <derived>/Build/Products/<Configuration>-iphoneos/<Name>.app
        let suffix = simulator ? "iphonesimulator" : "iphoneos"
        let producedApp = derived
            .appendingPathComponent("Build/Products")
            .appendingPathComponent("\(configuration)-\(suffix)")
            .appendingPathComponent("\(manifest.name).app")
        guard FileManager.default.fileExists(atPath: producedApp.path) else {
            throw BundlerError.binaryMissing(producedApp)
        }

        if simulator {
            // Copy alongside the macOS .app for consistent output paths,
            // and emit a one-liner the user can copy/paste to install.
            let dst = outputDir.appendingPathComponent("\(manifest.name).app")
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: producedApp, to: dst)
            print("""
            note: install + launch with:
              xcrun simctl boot "iPhone 16" 2>/dev/null || true
              xcrun simctl install booted "\(dst.path)"
              xcrun simctl launch booted \(manifest.ios?.bundleIdentifier ?? manifest.id)
            """)
            return dst
        }

        // Device: assemble Payload/ → .ipa.
        let payload = outputDir.appendingPathComponent("Payload")
        if FileManager.default.fileExists(atPath: payload.path) {
            try FileManager.default.removeItem(at: payload)
        }
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: producedApp,
            to: payload.appendingPathComponent("\(manifest.name).app")
        )
        let ipa = outputDir.appendingPathComponent("\(manifest.name).ipa")
        if FileManager.default.fileExists(atPath: ipa.path) {
            try FileManager.default.removeItem(at: ipa)
        }
        try await Shell.run("/usr/bin/env", ["zip", "-r", ipa.path, "Payload"], cwd: outputDir)
        return ipa
    }
}
