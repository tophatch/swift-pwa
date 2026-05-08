import ArgumentParser
import Foundation

enum BuildTarget: String, ExpressibleByArgument, CaseIterable {
    case macos, ios, linux, windows, android
}

struct Build: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Bundle the app for the chosen platform."
    )

    @Option(help: "Target platform: \(BuildTarget.allCases.map(\.rawValue).joined(separator: ", "))")
    var target: BuildTarget

    @Option(help: "Path to pwa.json. Defaults to ./pwa.json.")
    var manifest: String = "pwa.json"

    @Option(
        help: """
        Code-signing identity. Interpretation is per-platform: macOS / iOS — codesign \
        identity (e.g. "Developer ID Application: …"); Windows — signtool thumbprint or \
        PFX path; Android — path to a keystore (.jks / .keystore / .pkcs12). When set for \
        --target android, overrides pwa.json's android.signing.keystore.
        """
    )
    var sign: String?

    @Option(help: "Path to entitlements plist (macOS only).")
    var entitlements: String?

    @Flag(help: "Build for the iOS simulator (skips signing).")
    var simulator: Bool = false

    @Option(help: "Output directory for the bundled artifact. Defaults to ./build.")
    var output: String = "build"

    @Option(
        help: "Windows package format: portable (default) or msix."
    )
    var packageFormat: String = "portable"

    @Option(
        help: """
        Windows MSIX target architecture: x64 (default), x86, or arm64. Must match the architecture \
        of the Swift toolchain running the build — cross-compile on Swift-for-Windows is still rough, \
        so an arm64 MSIX needs to be produced from an arm64 host.
        """
    )
    var arch: String = "x64"

    @Flag(
        help: "Drop the WebView2 Evergreen Bootstrapper (~1.7 MB) into the Windows bundle."
    )
    var bootstrapWebview2: Bool = false

    @Option(
        help: """
        Comma-separated Android ABIs to include (e.g. arm64-v8a,x86_64). Overrides pwa.json's \
        android.abis. The CLI cross-compiles one .so per ABI when --cross-compile is set; \
        without it, the Gradle scaffold is generated and the developer is expected to drop \
        the .so files in by hand.
        """
    )
    var androidAbis: String?

    @Flag(
        help: """
        Run `swift build --triple <android-abi>` for each requested Android ABI and stage the \
        resulting .so files into the generated Gradle project. Off by default — most hosts \
        won't have a Swift Android SDK installed, and we don't want the Gradle scaffold to \
        fail to emit just because cross-compile didn't work.
        """
    )
    var crossCompileAndroid: Bool = false

    @Option(
        help: """
        Android-only: alias of the key inside the keystore passed via --sign (or declared \
        in pwa.json's android.signing.keystore). Overrides pwa.json's \
        android.signing.key_alias when set. Required when --sign is used without a \
        matching pwa.json signing section.
        """
    )
    var androidKeyAlias: String?

    @Flag(
        help: """
        Prune the bundled Swift runtime stdlib `.so` set to only what the app's `.so` actually \
        depends on (transitive `DT_NEEDED` walk via `readelf -d`). Drops 10 unused stdlib \
        modules on a typical app (`_Differentiation`, `_StringProcessing`, `RegexBuilder`, \
        `Distributed`, `FoundationXML`, `Testing`, `XCTest`, `Observation`, `_Volatile`, \
        `_SwiftOnoneSupport`). On `Examples/HelloPWA` this saves ~5 MB of APK on top of the \
        ~50 MB the always-on strip pass already saves (final APK 80 MB → 76 MB with prune \
        added). Off by default since the saving is small relative to the always-on strip — \
        opt in for distribution builds where every megabyte counts.
        """
    )
    var pruneAndroidRuntime: Bool = false

    func run() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let manifestURL = cwd.appendingPathComponent(manifest)
        let outputDir = cwd.appendingPathComponent(output)
        let pwa = try PWAManifest.load(from: manifestURL)

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        switch target {
        case .macos:
            let bundler = MacAppBundler(
                manifest: pwa,
                projectRoot: cwd,
                outputDir: outputDir,
                signIdentity: sign,
                entitlements: entitlements.map { URL(fileURLWithPath: $0) }
            )
            let url = try await bundler.build()
            print("Built: \(url.path)")
        case .ios:
            let bundler = IPABundler(
                manifest: pwa,
                projectRoot: cwd,
                outputDir: outputDir,
                signIdentity: sign,
                simulator: simulator
            )
            let url = try await bundler.build()
            print("Built: \(url.path)")
        case .linux:
            let bundler = AppImageBundler(
                manifest: pwa,
                projectRoot: cwd,
                outputDir: outputDir
            )
            let url = try await bundler.build()
            print("Built: \(url.path)")
        case .windows:
            let format: WindowsBundler.PackageFormat
            switch packageFormat.lowercased() {
            case "portable": format = .portable
            case "msix": format = .msix
            default:
                throw ValidationError(
                    "swift-pwa: --package-format must be 'portable' or 'msix' (got '\(packageFormat)')"
                )
            }
            let archValue = try AppxManifestGenerator.Architecture.parse(arch)
            let bundler = WindowsBundler(
                manifest: pwa,
                projectRoot: cwd,
                outputDir: outputDir,
                packageFormat: format,
                arch: archValue,
                bootstrapWebView2: bootstrapWebview2,
                signIdentity: sign
            )
            let url = try await bundler.build()
            print("Built: \(url.path)")
        case .android:
            // Resolve the ABI list: --android-abis overrides pwa.json's
            // android.abis, which falls back to the conventional pair.
            let abiList: [String] = if let raw = androidAbis, !raw.isEmpty {
                raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if let configured = pwa.android?.abis, !configured.isEmpty {
                configured
            } else {
                ["arm64-v8a", "x86_64"]
            }
            let bundler = AndroidBundler(
                manifest: pwa,
                projectRoot: cwd,
                outputDir: outputDir,
                abis: abiList,
                crossCompile: crossCompileAndroid,
                pruneRuntime: pruneAndroidRuntime,
                signKeystoreOverride: sign,
                keyAliasOverride: androidKeyAlias
            )
            let url = try await bundler.build()
            print("Built: \(url.path)")
            print("Next: cd '\(url.path)' && ./gradlew assembleDebug")
        }
    }
}
