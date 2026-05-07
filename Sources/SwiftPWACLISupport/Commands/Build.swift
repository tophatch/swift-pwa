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

    @Option(help: "Code-signing identity (macOS/iOS only).")
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
            print("swift-pwa: Android bundler is a stub in v0.1. Planned for v0.3.")
            throw ExitCode(2)
        }
    }
}
