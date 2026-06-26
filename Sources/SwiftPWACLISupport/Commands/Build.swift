import ArgumentParser
import Foundation

enum BuildTarget: String, ExpressibleByArgument, CaseIterable {
    case macos, ios, linux, windows, android

    /// The desktop target that matches the machine running the CLI, used
    /// as the default when `--target` is omitted. Only the three desktop
    /// hosts qualify — iOS / Android are cross-builds with no "this is my
    /// host" meaning, so they're always explicit.
    static var host: BuildTarget {
        #if os(macOS)
            .macos
        #elseif os(Linux)
            .linux
        #elseif os(Windows)
            .windows
        #else
            .macos
        #endif
    }
}

struct Build: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Bundle the app for the chosen platform.",
        discussion: """
        Runs against the SwiftPM scaffold created by `swift-pwa init` — it invokes `swift build` \
        (or `xcodebuild` for iOS) on the project's Package.swift, so it must be run from a project \
        root that has one. `pwa.json` + `web/` on their own aren't buildable; if you're adopting an \
        existing web app, run `swift-pwa init <Name> --in-place` first to add the native shell.
        """
    )

    @Option(
        help: """
        Target platform: \(BuildTarget.allCases.map(\.rawValue).joined(separator: ", ")). \
        Defaults to the host machine (\(BuildTarget.host.rawValue)) when omitted.
        """
    )
    var target: BuildTarget = .host

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

    @Option(
        help: "Path to an entitlements plist. macOS: passed to codesign. iOS (device): signed into the app — pair with --provisioning-profile."
    )
    var entitlements: String?

    @Option(
        help: """
        iOS device only: path to a provisioning profile (.mobileprovision). Embedded as \
        embedded.mobileprovision and (with --entitlements + --sign) makes the .ipa installable \
        on a device whose UDID the profile lists. See docs/ios-setup.md.
        """
    )
    var provisioningProfile: String?

    @Option(
        help: """
        iOS device only: a 10-character Apple Developer Team ID. A convenience that fills in \
        the signing inputs you didn't pass explicitly — it selects that team's "Apple \
        Development" identity (so --sign is optional) and finds an installed provisioning \
        profile matching the app's bundle id (so --provisioning-profile / --entitlements are \
        optional). Requires a profile Xcode/the portal already created for the bundle id; it \
        does not create one. Explicit flags win. See docs/ios-setup.md.
        """
    )
    var team: String?

    @Option(
        help: """
        macOS only: notarize the signed .app and staple the ticket, using this `notarytool` \
        keychain-profile name (create one once with `xcrun notarytool store-credentials`). \
        Requires --sign. Automates submit → wait → staple.
        """
    )
    var notarize: String?

    @Flag(help: "Build for the iOS simulator (skips signing).")
    var simulator: Bool = false

    @Flag(
        help: """
        Skip the pwa.json `build.prebuild` command. For fast local iteration when you know \
        the generated web/ assets are current — CI / release builds should never set this.
        """
    )
    var skipPrebuild: Bool = false

    @Flag(
        help: """
        Skip the pwa.json `build.postbuild` command (the after-bundling step). For fast local \
        iteration; CI / release builds should never set this.
        """
    )
    var skipPostbuild: Bool = false

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

        try Self.preflight(manifest: pwa, projectRoot: cwd)

        try await Self.runPrebuild(manifest: pwa, projectRoot: cwd, skip: skipPrebuild)

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let artifact: URL
        switch target {
        case .macos:
            let bundler = MacAppBundler(
                manifest: pwa,
                projectRoot: cwd,
                outputDir: outputDir,
                signIdentity: sign,
                entitlements: entitlements.map { URL(fileURLWithPath: $0) },
                notarizeProfile: notarize
            )
            artifact = try await bundler.build()
        case .ios:
            var signIdentity = sign
            var profileURL = provisioningProfile.map { URL(fileURLWithPath: $0) }
            var entitlementsURL = entitlements.map { URL(fileURLWithPath: $0) }
            // --team fills in only the signing inputs not passed explicitly
            // (explicit flags win). Device builds only — the simulator skips
            // signing entirely.
            if let team, !simulator {
                let bundleID = pwa.ios?.bundleIdentifier ?? pwa.id
                let resolved = await IOSSigning.resolve(team: team, bundleID: bundleID, scratch: outputDir)
                if signIdentity == nil, let id = resolved.identity {
                    signIdentity = id
                    print("swift-pwa: --team \(team) → signing identity \"\(id)\"")
                }
                if profileURL == nil, let profile = resolved.profile {
                    profileURL = profile
                    print("swift-pwa: --team \(team) → provisioning profile \(profile.lastPathComponent)")
                }
                if entitlementsURL == nil, let ent = resolved.entitlements {
                    entitlementsURL = ent
                    print("swift-pwa: --team \(team) → entitlements derived from the profile")
                }
                if signIdentity == nil || profileURL == nil {
                    print("""
                    swift-pwa: --team \(team) couldn't resolve \
                    \(signIdentity == nil ? "a signing identity" : "a provisioning profile") — \
                    pass it explicitly, or create one once in Xcode (see docs/ios-setup.md).
                    """)
                }
            }
            let bundler = IPABundler(
                manifest: pwa,
                projectRoot: cwd,
                outputDir: outputDir,
                signIdentity: signIdentity,
                entitlements: entitlementsURL,
                provisioningProfile: profileURL,
                simulator: simulator
            )
            artifact = try await bundler.build()
        case .linux:
            let bundler = AppImageBundler(
                manifest: pwa,
                projectRoot: cwd,
                outputDir: outputDir
            )
            artifact = try await bundler.build()
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
            artifact = try await bundler.build()
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
            artifact = try await bundler.build()
        }

        // After-bundling hook: runs on the produced artifact (path in
        // SWIFT_PWA_ARTIFACT) before we report success, so a failing
        // postbuild fails the build.
        try await Self.runPostbuild(
            manifest: pwa, projectRoot: cwd, target: target, artifact: artifact, skip: skipPostbuild
        )

        print("Built: \(artifact.path)")
        if target == .android {
            print("Next: cd '\(artifact.path)' && ./gradlew assembleDebug")
        }
    }

    /// Run `pwa.json`'s `build.prebuild` command (if any) from the project
    /// root, before any `web/` staging. This is the declared place for a
    /// codegen / asset step that produces part of `web/` — and because
    /// every `swift-pwa build` runs it, the generated release workflow
    /// (which just calls `swift-pwa build`) stays correct without a
    /// hand-maintained "regenerate before tagging" ritual. A non-zero exit
    /// aborts the build so a half-baked `web/` never ships.
    ///
    /// Runs through the platform shell so the string can use pipes /
    /// redirection / `&&`: `/bin/sh -c` on macOS / Linux, `cmd /c` on
    /// Windows. Stdio is inherited, so the command's output streams live.
    static func runPrebuild(manifest: PWAManifest, projectRoot: URL, skip: Bool) async throws {
        guard let command = manifest.build?.prebuild, !command.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }
        if skip {
            print("swift-pwa: skipping build.prebuild (--skip-prebuild): \(command)")
            return
        }
        print("swift-pwa: running build.prebuild: \(command)")
        #if os(Windows)
            let shell = "cmd"
            let shellArgs = ["/c", command]
        #else
            let shell = "/bin/sh"
            let shellArgs = ["-c", command]
        #endif
        do {
            try await Shell.run(shell, shellArgs, cwd: projectRoot)
        } catch {
            throw ValidationError(
                """
                build.prebuild failed: \(command)
                The prebuild step exited non-zero, so the build was aborted before staging web/ \
                (shipping a half-generated web/ is worse than failing). Fix the command above, or \
                pass --skip-prebuild to bypass it for a local iteration.
                """
            )
        }
    }

    /// Run `pwa.json`'s `build.postbuild` command (if any) from the project
    /// root, *after* the artifact is produced. The artifact's absolute path
    /// is exposed in `SWIFT_PWA_ARTIFACT` and the target name in
    /// `SWIFT_PWA_TARGET`, so the step can patch the generated bundle
    /// (Info.plist tweaks, extra signing, checksums) without the caller
    /// having to wrap the whole `swift-pwa build` invocation. A non-zero
    /// exit fails the build. Same shell semantics as `runPrebuild`.
    static func runPostbuild(
        manifest: PWAManifest, projectRoot: URL, target: BuildTarget, artifact: URL, skip: Bool
    ) async throws {
        guard let command = manifest.build?.postbuild, !command.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }
        if skip {
            print("swift-pwa: skipping build.postbuild (--skip-postbuild): \(command)")
            return
        }
        print("swift-pwa: running build.postbuild: \(command)")
        #if os(Windows)
            let shell = "cmd"
            let shellArgs = ["/c", command]
        #else
            let shell = "/bin/sh"
            let shellArgs = ["-c", command]
        #endif
        do {
            try await Shell.run(
                shell, shellArgs, cwd: projectRoot,
                envOverrides: ["SWIFT_PWA_ARTIFACT": artifact.path, "SWIFT_PWA_TARGET": target.rawValue]
            )
        } catch {
            throw ValidationError(
                """
                build.postbuild failed: \(command)
                The post-build step exited non-zero (artifact was at \(artifact.path)). Fix the \
                command above, or pass --skip-postbuild to bypass it for a local iteration.
                """
            )
        }
    }

    /// swift-pwa-level checks that run before any bundler shells out to
    /// `swift build` / `xcodebuild`, so failures surface as actionable
    /// guidance rather than a raw toolchain error after a long compile.
    static func preflight(manifest: PWAManifest, projectRoot: URL) throws {
        // 1. Every target builds the SwiftPM scaffold (`swift build` /
        // `xcodebuild` against the package). Without `Package.swift` the
        // underlying tool prints a generic "Could not find Package.swift"
        // that gives a newcomer no hint that swift-pwa projects need the
        // `init` scaffold — see the README quickstart.
        let packageSwift = projectRoot.appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: packageSwift.path) else {
            throw ValidationError(
                """
                No Package.swift found in \(projectRoot.path).
                swift-pwa apps need the SwiftPM scaffold (Package.swift + Sources/) that wraps your \
                web/ in a native shell — pwa.json + web/ alone isn't buildable. To create it:
                  - new project:      swift-pwa init <Name>
                  - existing web app: swift-pwa init <Name> --in-place
                Then run `swift-pwa build` from that project root.
                """
            )
        }

        // 2. The bundler discovers the built executable's name from the
        // package itself (`swift package describe`), so a `name` with
        // spaces is fine — the SwiftPM target name comes from
        // Package.swift, not from `name`. The one thing we *can* validate
        // up front is an explicit `executable_name` override: it has to
        // name a SwiftPM target, which can't contain whitespace. (When
        // unset, the probe resolves the real name; nothing to check.)
        if let exe = manifest.executableName, exe.contains(where: \.isWhitespace) {
            let suggestion = exe.split(whereSeparator: \.isWhitespace).joined()
            throw ValidationError(
                """
                pwa.json: `executable_name` ('\(exe)') contains whitespace, but it must match a \
                SwiftPM target name (the value after `name:` in Package.swift), which can't contain \
                spaces. Drop the spaces (e.g. "\(suggestion)"), or remove `executable_name` entirely \
                to let swift-pwa read the target name from the package.
                """
            )
        }
    }
}
