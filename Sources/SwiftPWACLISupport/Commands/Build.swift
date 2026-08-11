import ArgumentParser
import Foundation
#if os(Windows)
    import WinSDK // _putenv_s (ucrt) — `setenv` is POSIX-only
#endif

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

/// Which SwiftPM / xcodebuild configuration the app is compiled in.
///
/// Release is the default — a bundle is normally something you ship. `debug`
/// exists because the app driver's control socket is compiled into debug builds
/// only, so a release-only pipeline can't be driven: on the iOS simulator, where
/// `swift-pwa drive` is otherwise perfectly reachable over the shared loopback,
/// that made an iPad layout unverifiable except by screenshot-and-squint.
enum BuildConfiguration: String, ExpressibleByArgument, CaseIterable {
    case debug, release

    /// `swift build -c <value>`.
    var swiftPMValue: String {
        rawValue
    }
    /// `xcodebuild -configuration <value>` (capitalized).
    var xcodeValue: String {
        rawValue.capitalized
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

    @Option(
        help: """
        iOS device UDID (device builds only). Used by --allow-provisioning-registration to target \
        the device the throwaway minter project registers. When omitted, the sole connected device \
        is auto-detected (`xcrun devicectl list devices`).
        """
    )
    var device: String?

    @Flag(
        name: .long,
        help: """
        iOS device: let --team mint a provisioning profile for a free personal Apple team. When \
        --team resolves no installed profile for the bundle id, build a throwaway app project \
        against the target device (--device, or the sole connected one) with \
        -allowProvisioningUpdates -allowProvisioningDeviceRegistration, then sign with the profile \
        Xcode mints. Echoes xcodebuild's own flag; macOS-only. See docs/ios-setup.md.
        """
    )
    var allowProvisioningRegistration: Bool = false

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

    @Option(
        help: """
        Output directory for the bundled artifact. Defaults to a per-target directory under ./build \
        (build/macos, build/ios, build/ios-simulator, build/linux, build/windows, build/android) so \
        the Apple targets — which both write <name>.app — can't overwrite each other. An explicit \
        --output is used verbatim.
        """
    )
    var output: String?

    @Option(
        help: "Windows package format: portable (default) or msix."
    )
    var packageFormat: String = "portable"

    @Option(
        parsing: .singleValue,
        help: """
        Target architecture. Repeatable on macOS — pass it twice (--arch arm64 --arch x86_64) for a \
        universal .app; omit it for the host's architecture. On Windows it names the MSIX \
        architecture (x64 (default), x86, or arm64) and takes a single value that must match the \
        Swift toolchain running the build — cross-compile on Swift-for-Windows is still rough, so an \
        arm64 MSIX needs an arm64 host. Ignored on Linux / iOS / Android.
        """
    )
    var arch: [String] = []

    @Option(
        help: """
        Build configuration: release (default) or debug. Applies to macOS / iOS / Linux / Windows. \
        Use debug to get a driveable build — the app driver's control socket is compiled into debug \
        builds only (see docs/app-driver.md). On Android the Swift library is always release; the \
        APK variant is chosen when you assemble it (`deploy --release`).
        """
    )
    var configuration: BuildConfiguration = .release

    @Flag(
        help: "Drop the WebView2 Evergreen Bootstrapper (~1.7 MB) into the Windows bundle."
    )
    var bootstrapWebview2: Bool = false

    @Flag(
        help: """
        Windows portable only: embed web/ into the .exe and emit a single \
        self-contained .exe instead of a folder. The runtime serves the bundle \
        from memory. Not compatible with --package-format msix.
        """
    )
    var singleFile: Bool = false

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
        name: .long,
        help: .hidden // set by `deploy`, which runs gradlew itself, so the "Next: ./gradlew …" hint would mislead
    )
    var noNextSteps: Bool = false

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
        let outputDir = cwd.appendingPathComponent(Self.resolveOutput(output, target: target, simulator: simulator))
        let pwa = try PWAManifest.load(from: manifestURL)
        try Self.validateArchs(arch, target: target)

        let stamp = BuildStamp(
            target: target.rawValue,
            destination: target == .ios ? (simulator ? "simulator" : "device") : nil,
            name: pwa.name,
            configuration: configuration.rawValue,
            cliVersion: SwiftPWAVersion.current
        )
        try BuildStamp.checkCompatible(directory: outputDir, with: stamp)

        try Self.preflight(manifest: pwa, projectRoot: cwd)
        await Self.reportToolGaps(target: target, crossCompileAndroid: crossCompileAndroid)

        try await Self.applyLocalLlamaGate(manifest: pwa, target: target, projectRoot: cwd)
        Self.applyGeminiNanoGate(manifest: pwa, target: target)
        Self.applyPhiSilicaGate(manifest: pwa, target: target)
        try await Self.applyLocalOnnxRuntimeGate(manifest: pwa, target: target, projectRoot: cwd)

        try await Self.runPrebuild(manifest: pwa, projectRoot: cwd, skip: skipPrebuild)

        // The web bundle must exist *now* — after any prebuild that generates
        // it, before we hand off to a bundler that would otherwise copy
        // nothing. A prebuild "ran" only if one is configured and not skipped;
        // that tunes the failure hint.
        let prebuildRan = !skipPrebuild
            && (pwa.build?.prebuild?.trimmingCharacters(in: .whitespaces).isEmpty == false)
        try Self.checkWebBundle(manifest: pwa, projectRoot: cwd, prebuildRan: prebuildRan)
        try await Self.validateAgentSurface(manifest: pwa, projectRoot: cwd, target: target)

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
                notarizeProfile: notarize,
                archs: arch,
                configuration: configuration
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
                // Free personal team: no installed profile to find. With the
                // opt-in flag, mint one by building a throwaway app project
                // against the target device (registering it). See
                // PersonalTeamProfileMinter / docs/ios-setup.md.
                if profileURL == nil, allowProvisioningRegistration {
                    let target = try await IOSDeviceResolver.resolve(explicit: device)
                    print("swift-pwa: --team \(team) found no installed profile — minting one on \(target.name).")
                    let minted = try await PersonalTeamProfileMinter.mint(
                        bundleID: bundleID, team: team, deviceUDID: target.udid, scratch: outputDir
                    )
                    profileURL = minted.profile
                    print("swift-pwa: minted provisioning profile \(minted.profile.lastPathComponent)")
                    if entitlementsURL == nil, let ent = minted.entitlements { entitlementsURL = ent }
                    // The minted free-team profile names the cert that may sign
                    // it; the team-string identity match above won't have found
                    // it (free-team cert CN carries a different id).
                    if signIdentity == nil, let id = await IOSSigning.identity(forProfileAt: minted.profile) {
                        signIdentity = id
                        print("swift-pwa: signing identity \"\(id)\" (from the minted profile)")
                    }
                }
                if signIdentity == nil || profileURL == nil {
                    let hint = profileURL == nil && !allowProvisioningRegistration
                        ? " (for a free personal team, add --allow-provisioning-registration to mint one)"
                        : ""
                    print("""
                    swift-pwa: --team \(team) couldn't resolve \
                    \(signIdentity == nil ? "a signing identity" : "a provisioning profile")\(hint) — \
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
                simulator: simulator,
                configuration: configuration
            )
            artifact = try await bundler.build()
        case .linux:
            let bundler = AppImageBundler(
                manifest: pwa,
                projectRoot: cwd,
                outputDir: outputDir,
                configuration: configuration
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
            let archValue = try AppxManifestGenerator.Architecture.parse(arch.first ?? "x64")
            if singleFile, format == .msix {
                throw ValidationError(
                    "swift-pwa: --single-file is for the portable format; MSIX already packages "
                        + "everything into one installable. Drop --single-file or --package-format msix."
                )
            }
            let bundler = WindowsBundler(
                manifest: pwa,
                projectRoot: cwd,
                outputDir: outputDir,
                packageFormat: format,
                arch: archValue,
                bootstrapWebView2: bootstrapWebview2,
                signIdentity: sign,
                singleFile: singleFile,
                configuration: configuration
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
            // The cross-compiler must match the Android SDK's Swift release
            // exactly, or the build fails deep with a "module compiled with
            // Swift X cannot be imported by the Swift Y compiler" error. When
            // cross-compiling, pick the matching xctoolchain automatically so
            // the user doesn't have to `export TOOLCHAINS=…` by hand.
            if crossCompileAndroid { Self.selectAndroidToolchainIfNeeded() }
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

        // Record what this directory now holds, so a later build for another
        // platform refuses rather than overwriting it (see BuildStamp).
        try stamp.write(to: outputDir)

        // After-bundling hook: runs on the produced artifact (path in
        // SWIFT_PWA_ARTIFACT) before we report success, so a failing
        // postbuild fails the build.
        try await Self.runPostbuild(
            manifest: pwa, projectRoot: cwd, target: target, artifact: artifact, skip: skipPostbuild
        )

        print("Built: \(artifact.path)")
        if target == .android, !noNextSteps {
            print("Next: cd '\(artifact.path)' && ./gradlew assembleDebug")
        }
    }

    /// The output directory: an explicit `--output` verbatim, else a per-target
    /// directory under `build/`. Shared with `deploy`, which resolves the same
    /// path to find what the build produced.
    static func resolveOutput(_ explicit: String?, target: BuildTarget, simulator: Bool) -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        return "build/\(target.outputSubdirectory(simulator: simulator))"
    }

    /// `--arch` means different things per platform, so reject the combinations
    /// that would otherwise be silently ignored (a universal build that quietly
    /// produced one slice is worse than an error).
    static func validateArchs(_ archs: [String], target: BuildTarget) throws {
        guard !archs.isEmpty else { return }
        switch target {
        case .macos:
            let supported = ["arm64", "x86_64"]
            for arch in archs where !supported.contains(arch) {
                throw ValidationError(
                    "swift-pwa: --arch \(arch) isn't a macOS architecture — pass arm64 and/or x86_64 "
                        + "(both, for a universal .app)."
                )
            }
            if Set(archs).count != archs.count {
                throw ValidationError("swift-pwa: --arch was repeated with the same value.")
            }
        case .windows:
            if archs.count > 1 {
                throw ValidationError(
                    "swift-pwa: --target windows takes a single --arch (the MSIX architecture); it must "
                        + "match the Swift toolchain running the build."
                )
            }
        case .ios, .linux, .android:
            throw ValidationError(
                "swift-pwa: --arch isn't used for --target \(target.rawValue). iOS builds both device "
                    + "slices via xcodebuild; Android's architectures are --android-abis; Linux builds "
                    + "for the host."
            )
        }
    }

    /// Honor `pwa.json`'s `ai.local_llama` by exporting `SWIFT_PWA_LLAMA=1`
    /// into this process's environment, which the underlying `swift build` /
    /// `xcodebuild` children inherit (so SwiftPM's manifest evaluation includes
    /// the `SwiftPWALlama` target + its platform `CLlama` backend). Adopters
    /// never set the env var by hand — the pwa.json flag is the knob.
    ///
    /// Per platform:
    /// - **Apple (macOS / iOS)** — just set the flag; SwiftPM's `.binaryTarget`
    ///   downloads + checksum-verifies the llama xcframework (Metal).
    /// - **Linux** — there's no binary-library target, so additionally fetch the
    ///   prebuilt `libllama.a` (Vulkan) and prepend its directory to
    ///   `LIBRARY_PATH` so the child `swift build` resolves `-lllama`. Requires a
    ///   host Vulkan dev lib (`libvulkan-dev`) at link time + a Vulkan driver at
    ///   runtime. See `LlamaLinuxArtifact`.
    /// - **Windows** — like Linux, no binary-library target, so fetch the
    ///   prebuilt `llama.lib` and prepend its directory to `LIB` (the
    ///   MSVC-linker search-path env var, the Windows counterpart to Linux's
    ///   `LIBRARY_PATH` — the same trick `CWebView2Shim` uses) so the child
    ///   `swift build` resolves `llama.lib`. On **x64** the lib is the Vulkan
    ///   build, so this also needs the Vulkan SDK's `vulkan-1.lib` at link time
    ///   + a Vulkan driver at runtime; on **arm64** (Copilot+) the lib is
    ///   **CPU-only** by default, so no Vulkan SDK is needed — unless the
    ///   experimental `LLAMA_WIN_ARM64_VULKAN` opt-in is set (Adreno Vulkan; output
    ///   currently garbage, for re-testing only). See `LlamaWindowsArtifact`.
    /// - **Android** — not supported yet; warn and ignore.
    static func applyLocalLlamaGate(manifest: PWAManifest, target: BuildTarget, projectRoot: URL) async throws {
        guard manifest.ai?.localLlama == true else { return }
        switch target {
        case .macos, .ios:
            #if !os(Windows)
                setenv("SWIFT_PWA_LLAMA", "1", 1)
            #endif
            print("swift-pwa: ai.local_llama → bundling the on-device llama.cpp backend (SwiftPWALlama)")
        case .linux:
            #if os(Linux)
                let libDir = try await LlamaLinuxArtifact.ensureLibDir(projectRoot: projectRoot)
                setenv("SWIFT_PWA_LLAMA", "1", 1)
                // Prepend so our lib wins, but keep any existing search path.
                let existing = ProcessInfo.processInfo.environment["LIBRARY_PATH"]
                let combined = existing.map { "\(libDir.path):\($0)" } ?? libDir.path
                setenv("LIBRARY_PATH", combined, 1)
                print(
                    "swift-pwa: ai.local_llama → bundling the on-device llama.cpp backend "
                        + "(SwiftPWALlama, Vulkan); libllama.a from \(libDir.path)"
                )
            #else
                print(
                    "swift-pwa: ai.local_llama for --target linux must be run on a Linux host — "
                        + "ignoring it for this build."
                )
            #endif
        case .windows:
            #if os(Windows)
                let libDir = try await LlamaWindowsArtifact.ensureLibDir(projectRoot: projectRoot)
                // `_putenv_s` (not POSIX `setenv`) so both the CRT and Win32
                // environment blocks update — `ProcessInfo.environment` reads the
                // latter, and `WindowsBundler.resolvePackageEnvOverrides` reads
                // `LIB` back through it to build the child `swift build`'s env.
                _ = _putenv_s("SWIFT_PWA_LLAMA", "1")
                // Build the LIB search path: our llama.lib dir, plus (x64 only)
                // the Vulkan SDK's `Lib` (for `vulkan-1.lib`, the loader import
                // library that `.linkedLibrary("vulkan-1")` needs at link time —
                // the SDK sets VULKAN_SDK but does NOT add its Lib to LIB), plus
                // whatever's already there. `;`-separated; case-insensitive LIB
                // lookup since a VS dev shell exports `Lib` (PowerShell) or `LIB`
                // (cmd). The Vulkan SDK's Lib is appended only for a Vulkan build:
                // x64 always; arm64 only under the EXPERIMENTAL `LLAMA_WIN_ARM64_VULKAN`
                // opt-in (default arm64 is CPU-only — no `vulkan-1` to find — and the
                // Adreno X1's Vulkan output is currently garbage; see docs).
                let env = ProcessInfo.processInfo.environment
                var search = [libDir.path]
                #if arch(arm64)
                    let wantVulkan = env["LLAMA_WIN_ARM64_VULKAN"] != nil
                    let backend = wantVulkan ? "Vulkan — EXPERIMENTAL/arm64" : "CPU"
                #else
                    let wantVulkan = true
                    let backend = "Vulkan"
                #endif
                if wantVulkan {
                    if let sdk = env["VULKAN_SDK"], !sdk.isEmpty {
                        search.append("\(sdk)\\Lib")
                    } else {
                        print(
                            "swift-pwa: warning — VULKAN_SDK is not set, so the link step can't find "
                                + "vulkan-1.lib. Install the Vulkan SDK (it sets VULKAN_SDK); see "
                                + "docs/windows-setup.md."
                        )
                    }
                }
                let existing = env.first { $0.key.caseInsensitiveCompare("LIB") == .orderedSame }?.value
                let combined = (existing.map { search + [$0] } ?? search).joined(separator: ";")
                _ = _putenv_s("LIB", combined)
                print(
                    "swift-pwa: ai.local_llama → bundling the on-device llama.cpp backend "
                        + "(SwiftPWALlama, \(backend)); llama.lib from \(libDir.path)"
                )
            #else
                print(
                    "swift-pwa: ai.local_llama for --target windows must be run on a Windows host — "
                        + "ignoring it for this build."
                )
            #endif
        default:
            print(
                "swift-pwa: ai.local_llama is set but the llama.cpp backend isn't supported on "
                    + "\(target) yet — ignoring it for this build."
            )
        }
    }

    /// Honor `pwa.json`'s `ai.gemini_nano`. Unlike llama, the Gemini Nano
    /// backend (`GeminiNanoBackend`) is compiled into `SwiftPWAAndroid`
    /// unconditionally — it's a thin RPC client with no binary artifact — so
    /// there's no SwiftPM env gate to set here. The `AndroidBundler` reads the
    /// flag directly to add the `com.google.mlkit:genai-prompt` Gradle
    /// dependency and splice the `ai.gemini.*` Kotlin dispatch. This just
    /// prints a confirmation on Android and warns when the flag is set for a
    /// target that can't use it (Gemini Nano is Android-only).
    static func applyGeminiNanoGate(manifest: PWAManifest, target: BuildTarget) {
        guard manifest.ai?.geminiNano == true else { return }
        if target == .android {
            print("swift-pwa: ai.gemini_nano → bundling the Android Gemini Nano backend (ML Kit GenAI)")
        } else {
            print(
                "swift-pwa: ai.gemini_nano is set but Gemini Nano is Android-only — "
                    + "ignoring it for \(target). Use ai.local_llama or a platform built-in instead."
            )
        }
    }

    /// Honor `pwa.json`'s `ai.phi_silica` by exporting `SWIFT_PWA_PHI_SILICA=1`
    /// so the child `swift build`'s manifest evaluation includes the
    /// `SwiftPWAPhiSilica` target (Windows Phi Silica via the Windows App SDK).
    /// Windows-only; warns when set for another target. The Windows App SDK
    /// headers/bootstrapper still have to be on the build's INCLUDE/LIB path
    /// (see docs/windows-setup.md) — this only flips the manifest gate.
    static func applyPhiSilicaGate(manifest: PWAManifest, target: BuildTarget) {
        guard manifest.ai?.phiSilica == true else { return }
        switch target {
        case .windows:
            #if os(Windows)
                _ = _putenv_s("SWIFT_PWA_PHI_SILICA", "1")
            #endif
            print("swift-pwa: ai.phi_silica → bundling the Windows Phi Silica backend (Windows AI / Windows App SDK)")
        default:
            print(
                "swift-pwa: ai.phi_silica is set but Phi Silica is Windows-only — "
                    + "ignoring it for \(target). Use the platform's built-in (Foundation Models / "
                    + "Gemini Nano) or ai.local_llama instead."
            )
        }
    }

    /// Honor `pwa.json`'s `ai.local_onnx_runtime` by exporting
    /// `SWIFT_PWA_ONNXRUNTIME=1` so the child `swift build`'s manifest
    /// evaluation includes `SwiftPWASegmentation` (the `ai.vision.*` /
    /// `MobileSAMBackend` tier). Apple + Android only.
    ///
    /// This only flips the manifest gate — the actual native artifact
    /// resolution differs per platform:
    /// - **Apple** — nothing further needed here; SwiftPM's `.binaryTarget`
    ///   downloads + checksum-verifies the ONNX Runtime xcframework.
    /// - **Android** — no per-arch work happens here, because Android
    ///   cross-compiles multiple ABIs in one build and each needs its own
    ///   `libonnxruntime.so` on `LIBRARY_PATH` for that ABI's link step
    ///   alone. `AndroidBundler.stageJniLibs` reads this same
    ///   `manifest.ai?.localOnnxRuntime` flag directly and resolves +
    ///   stages the `.so` per ABI via `OnnxRuntimeAndroidArtifact` inside
    ///   its cross-compile loop.
    static func applyLocalOnnxRuntimeGate(manifest: PWAManifest, target: BuildTarget, projectRoot: URL) async throws {
        // `ai.onnx_gpu` (desktop GPU execution providers — DirectML on Windows,
        // CUDA on Linux; see docs/proposals/onnx-gpu-execution-providers.md)
        // implies the ONNX Runtime tier, so either flag enables it.
        let onnxGpu = manifest.ai?.onnxGpu == true
        guard manifest.ai?.localOnnxRuntime == true || onnxGpu else { return }
        switch target {
        case .macos, .ios:
            #if !os(Windows)
                setenv("SWIFT_PWA_ONNXRUNTIME", "1", 1)
            #endif
            if onnxGpu { warnOnnxGpuIgnored(target: target) }
            print("swift-pwa: ai.local_onnx_runtime → bundling the on-device ONNX Runtime tier (SwiftPWASegmentation)")
        case .android:
            #if !os(Windows)
                setenv("SWIFT_PWA_ONNXRUNTIME", "1", 1)
            #endif
            if onnxGpu { warnOnnxGpuIgnored(target: target) }
            print(
                "swift-pwa: ai.local_onnx_runtime → bundling the on-device ONNX Runtime tier "
                    + "(SwiftPWASegmentation); libonnxruntime.so resolved per-ABI during cross-compile"
            )
        case .linux:
            // ONNX Runtime desktop is a *shared* lib (unlike llama's static
            // Linux slice), so the dir goes on LIBRARY_PATH for the link step
            // here and the `.so`(s) are staged into the AppImage at runtime (see
            // LinuxBundler, which re-resolves via the same idempotent call).
            #if os(Linux)
                // GPU (CUDA 12) resolves three libs; CPU resolves one. Both put
                // the dir on LIBRARY_PATH; the GPU build additionally defines
                // SWIFT_PWA_ONNXRUNTIME_GPU so the manifest links the CUDA-aware
                // module and OrtModelSession compiles the CUDA EP append.
                let libDir = onnxGpu
                    ? try await OnnxRuntimeLinuxGpuArtifact.ensureLibDir(projectRoot: projectRoot)
                    : try await OnnxRuntimeLinuxArtifact.ensureLibDir(projectRoot: projectRoot)
                setenv("SWIFT_PWA_ONNXRUNTIME", "1", 1)
                if onnxGpu { setenv("SWIFT_PWA_ONNXRUNTIME_GPU", "1", 1) }
                let existing = ProcessInfo.processInfo.environment["LIBRARY_PATH"]
                setenv("LIBRARY_PATH", existing.map { "\(libDir.path):\($0)" } ?? libDir.path, 1)
                print(
                    "swift-pwa: ai.local_onnx_runtime → bundling the on-device ONNX Runtime tier "
                        + "(SwiftPWASegmentation, \(onnxGpu ? "GPU/CUDA" : "CPU")); libonnxruntime.so from \(libDir.path)"
                )
            #else
                print(
                    "swift-pwa: ai.local_onnx_runtime for --target linux must be run on a Linux host — "
                        + "ignoring it for this build."
                )
            #endif
        case .windows:
            #if os(Windows)
                // GPU (DirectML) resolves onnxruntime.lib/.dll +
                // onnxruntime_providers_shared.dll + DirectML.dll; CPU resolves
                // the lib/.dll pair. Both put the dir on LIB; the GPU build
                // additionally defines SWIFT_PWA_ONNXRUNTIME_GPU so the manifest
                // links the DirectML module (its own pinned 1.24.4 headers) and
                // OrtModelSession compiles the DirectML EP append.
                let libDir = onnxGpu
                    ? try await OnnxRuntimeWindowsDirectMLArtifact.ensureLibDir(projectRoot: projectRoot)
                    : try await OnnxRuntimeWindowsArtifact.ensureLibDir(projectRoot: projectRoot)
                // `_putenv_s` (not POSIX `setenv`) so both CRT + Win32 env
                // blocks update — WindowsBundler reads `LIB` back through
                // ProcessInfo. The runtime DLLs from the same dir are staged
                // next to the .exe by WindowsBundler.
                _ = _putenv_s("SWIFT_PWA_ONNXRUNTIME", "1")
                if onnxGpu { _ = _putenv_s("SWIFT_PWA_ONNXRUNTIME_GPU", "1") }
                let env = ProcessInfo.processInfo.environment
                let existing = env.first { $0.key.caseInsensitiveCompare("LIB") == .orderedSame }?.value
                let combined = (existing.map { [libDir.path, $0] } ?? [libDir.path]).joined(separator: ";")
                _ = _putenv_s("LIB", combined)
                print(
                    "swift-pwa: ai.local_onnx_runtime → bundling the on-device ONNX Runtime tier "
                        + "(SwiftPWASegmentation, \(onnxGpu ? "GPU/DirectML" : "CPU")); onnxruntime.lib from \(libDir.path)"
                )
            #else
                print(
                    "swift-pwa: ai.local_onnx_runtime for --target windows must be run on a Windows host — "
                        + "ignoring it for this build."
                )
            #endif
        }
    }

    /// `ai.onnx_gpu` is desktop-only (Windows DirectML / Linux CUDA). On
    /// Apple/Android the OS/EP owns GPU acceleration, so the flag is a no-op —
    /// warn so a misplaced flag isn't silently mistaken for a GPU build.
    private static func warnOnnxGpuIgnored(target: BuildTarget) {
        print(
            "swift-pwa: ai.onnx_gpu is set but the ONNX Runtime GPU tier is desktop-only "
                + "(Windows DirectML / Linux CUDA) — ignoring it for \(target); "
                + "the CPU ONNX Runtime tier still ships."
        )
    }

    /// Resolve `pwa.json`'s `agent.expose` allowlist against the app's real
    /// command catalog, and fail the build if it names something that isn't
    /// there. See ``PWAManifest/AgentSection``.
    ///
    /// The catalog comes from a headless run of the app itself, so this can
    /// only happen when the built binary runs on the build host — a
    /// cross-compiled Android / iOS / foreign-desktop artifact can't be asked
    /// what it registered. Rather than silently skip, say so and point at
    /// `swift-pwa agent check`, which does the host build on its own.
    ///
    /// Uses the release configuration the bundlers build with, so the dump
    /// warms the same build products instead of adding a second one.
    static func validateAgentSurface(manifest: PWAManifest, projectRoot: URL, target: BuildTarget) async throws {
        guard let expose = manifest.agent?.expose, !expose.isEmpty else { return }
        guard target == .host else {
            print("""
            swift-pwa: agent.expose not checked for --target \(target.rawValue) — validating it means running \
            the app, and this build is cross-compiled. Run `swift-pwa agent check` on a host that can run it.
            """)
            return
        }
        let dump = try await CommandCatalog.dumpAll(
            projectRoot: projectRoot, manifest: manifest, configuration: "release", quiet: true
        )
        try AgentCheck.report(AgentPolicy.resolve(manifest.agent, against: dump.commands), appName: manifest.name)
        try AgentCheck.reportDrift(AgentPolicy.drift(declared: manifest.agent, compiled: dump.agentTools))
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

    /// Quiet toolchain preflight: reuse `doctor`'s required-tool checks and,
    /// if any are missing, print one concise heads-up pointing at `doctor`
    /// for the fixes — then continue (a probe false-negative shouldn't block
    /// a build; the bundler surfaces the real error if the tool is truly
    /// absent). Says nothing on a healthy machine, so it adds no noise to the
    /// common case.
    ///
    /// Android is skipped unless `--cross-compile-android` is set: a plain
    /// `build --target android` only emits the Gradle scaffold, so its
    /// heavier prerequisites (NDK, Swift Android SDK, JDK-for-Gradle) aren't
    /// needed yet and flagging them would be a false alarm.
    static func reportToolGaps(target: BuildTarget, crossCompileAndroid: Bool) async {
        if target == .android, !crossCompileAndroid { return }
        let gaps = await Doctor.requiredToolGaps(for: target)
        guard !gaps.isEmpty else { return }
        let names = gaps.map(\.label).joined(separator: ", ")
        print("swift-pwa: missing required tool(s) for \(target.rawValue): \(names).")
        print("           Run `swift-pwa doctor --target \(target.rawValue)` for the fixes.")
    }

    /// Select the Swift toolchain that matches the installed Android SDK, by
    /// exporting `TOOLCHAINS` for the child `swift build --swift-sdk …` the
    /// `AndroidBundler` runs. The Swift Android SDK's modules are built with
    /// one specific Swift release, and the compiler enforces an exact match —
    /// cross-compiling a 6.2 SDK with the host's 6.3 default toolchain fails
    /// with `module compiled with Swift 6.2 cannot be imported by the Swift
    /// 6.3 compiler`. The fix is to run the cross-build under the matching
    /// release toolchain; today the adopter does that by hand
    /// (`export TOOLCHAINS=<bundle id>`, or wrapping in `swiftly run +6.2.0`).
    /// The CLI can do it itself: derive the needed release from the installed
    /// Android SDK bundle, then find the like-versioned `.xctoolchain` and use
    /// its bundle id.
    ///
    /// macOS-only — this is the xctoolchain / `TOOLCHAINS` mechanism, which is
    /// an Apple-toolchain concept. On a Linux host the matching is done via
    /// `swiftly` (see docs/android-setup.md), so this is a no-op there.
    ///
    /// Non-fatal by design: an explicit `TOOLCHAINS` (or a swiftly-pinned run)
    /// always wins, and when the SDK/toolchain can't be resolved we print a
    /// hint and continue rather than block — the host's default toolchain may
    /// already match.
    static func selectAndroidToolchainIfNeeded() {
        #if os(macOS)
            let env = ProcessInfo.processInfo.environment
            // An explicit override (or a `swiftly run +X` wrapper, which pins
            // the compiler a different way) wins — don't second-guess it.
            if let existing = env["TOOLCHAINS"], !existing.isEmpty {
                print("swift-pwa: cross-compile toolchain: TOOLCHAINS=\(existing) (from the environment)")
                return
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            guard let version = installedAndroidSDKSwiftVersion(home: home) else {
                // No installed Android SDK bundle found to key off — say
                // nothing (the bundler's own `swift sdk list` preflight will
                // give the real diagnostic if none is installed).
                return
            }
            guard let toolchain = releaseToolchain(matchingSwiftVersion: version, home: home) else {
                print(
                    "swift-pwa: note — the installed Android SDK needs the Swift \(version) toolchain, but no "
                        + "swift-\(version)-RELEASE*.xctoolchain is installed. If the build fails with a "
                        + "\"module compiled with Swift \(version)\" error, install it "
                        + "(e.g. `swiftly install \(version).0`) or set TOOLCHAINS by hand — see docs/android-setup.md."
                )
                return
            }
            setenv("TOOLCHAINS", toolchain.bundleID, 1)
            print(
                "swift-pwa: cross-compile toolchain: \(toolchain.bundleID) "
                    + "(\(toolchain.name), matched to the Swift \(version) Android SDK)"
            )
        #endif
    }

    #if os(macOS)
        /// The Swift release (`"6.2"`) an installed Android SDK bundle was
        /// built with, read from the SwiftPM swift-sdks directory. Bundles are
        /// named `swift-<version>-RELEASE-android-<n>.artifactbundle`.
        private static func installedAndroidSDKSwiftVersion(home: URL) -> String? {
            let sdksDir = home
                .appendingPathComponent("Library/org.swift.swiftpm/swift-sdks")
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: sdksDir, includingPropertiesForKeys: nil
            ) else { return nil }
            for entry in entries.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                if let v = swiftReleaseVersion(in: entry.lastPathComponent, marker: "-RELEASE-android") {
                    return v
                }
            }
            return nil
        }

        /// The installed release `.xctoolchain` whose version matches
        /// `version` (e.g. `"6.2"`), as `(bundleID, name)`. Prefers the exact
        /// `swift-<version>-RELEASE.xctoolchain`; falls back to any
        /// `swift-<version>-RELEASE*.xctoolchain` (snapshot dev toolchains of
        /// the same release line). Returns `nil` if none is installed or the
        /// `Info.plist` has no `CFBundleIdentifier`.
        private static func releaseToolchain(
            matchingSwiftVersion version: String, home: URL
        ) -> (bundleID: String, name: String)? {
            let dir = home.appendingPathComponent("Library/Developer/Toolchains")
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { return nil }
            let candidates = entries.filter {
                $0.pathExtension == "xctoolchain"
                    && $0.lastPathComponent.hasPrefix("swift-\(version)-RELEASE")
            }
            // Exact `swift-<v>-RELEASE.xctoolchain` first, then anything else.
            // Rank exact=0/other=1 so the comparator is a real strict-weak
            // ordering (a bare `a == exact` predicate isn't, and yields
            // undefined results when several candidates exist).
            let exact = "swift-\(version)-RELEASE.xctoolchain"
            let ordered = candidates.sorted { a, b in
                (a.lastPathComponent == exact ? 0 : 1) < (b.lastPathComponent == exact ? 0 : 1)
            }
            for toolchain in ordered {
                let plist = toolchain.appendingPathComponent("Info.plist")
                guard let data = try? Data(contentsOf: plist),
                      let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
                      let dict = obj as? [String: Any],
                      let id = dict["CFBundleIdentifier"] as? String
                else { continue }
                return (id, toolchain.lastPathComponent)
            }
            return nil
        }

        /// Extract a `major.minor` Swift version that immediately precedes
        /// `marker` in a `swift-<version>-…` string, e.g. `"6.2"` from
        /// `swift-6.2-RELEASE-android-0.1`. Ignores any patch component.
        /// (internal, not private, so it's unit-testable on macOS.)
        static func swiftReleaseVersion(in name: String, marker: String) -> String? {
            guard name.hasPrefix("swift-"), let markerRange = name.range(of: marker) else { return nil }
            let versionPart = name[name.index(name.startIndex, offsetBy: "swift-".count) ..< markerRange.lowerBound]
            let comps = versionPart.split(separator: ".")
            guard comps.count >= 2, comps.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
            return "\(comps[0]).\(comps[1])"
        }
    #endif

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

    /// Fail the build up front when the web bundle the app will load is
    /// missing, empty, or lacks its entry file — instead of letting the
    /// bundler silently copy nothing (every bundler's web-copy is a bare
    /// `if fileExists { copyItem }` with no else) and the app `fatalError`
    /// at runtime with "web bundle not found", or worse hand the user a
    /// blank window. This bites anyone who forgets `npm run build`, misnames
    /// `web.directory`, or has a prebuild that doesn't write where expected.
    ///
    /// Runs *after* `build.prebuild`, since that step is the declared place
    /// to *generate* `web/`; `prebuildRan` tunes the failure hint toward the
    /// likely cause. Applies to every target — even a Windows `--single-file`
    /// build reads `web/` off disk to embed it.
    static func checkWebBundle(manifest: PWAManifest, projectRoot: URL, prebuildRan: Bool) throws {
        let fm = FileManager.default
        let dir = manifest.web.directory
        let webDir = projectRoot.appendingPathComponent(dir)

        // The "how do I fix this" tail, tuned to whether a prebuild is in play
        // (the usual way `web/` gets generated).
        let hint = prebuildRan
            ? """
            A `build.prebuild` ran but didn't produce it — check that the command actually writes into \
            this directory, and that `web.directory` names its output dir.
            """
            : """
            Build your web assets into it first (e.g. `npm run build`), or point `web.directory` at the \
            right output dir. To run the build automatically on every `swift-pwa build`, declare it as \
            `build.prebuild` in pwa.json.
            """

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: webDir.path, isDirectory: &isDir) else {
            throw ValidationError(
                """
                web bundle not found: \(webDir.path)
                pwa.json's `web.directory` is "\(dir)", but nothing exists there — the app would ship \
                with no web assets and fail to launch.
                \(hint)
                """
            )
        }
        guard isDir.boolValue else {
            throw ValidationError(
                """
                web bundle is not a directory: \(webDir.path)
                pwa.json's `web.directory` ("\(dir)") must be a directory of your built web assets, not a file.
                """
            )
        }

        // Ignore dotfiles (a lone `.gitkeep` doesn't make a bundle) so an
        // otherwise-empty dir reports the clearer "empty" message.
        let contents = (try? fm.contentsOfDirectory(atPath: webDir.path))?.filter { !$0.hasPrefix(".") } ?? []
        guard !contents.isEmpty else {
            throw ValidationError(
                """
                web bundle is empty: \(webDir.path)
                pwa.json's `web.directory` ("\(dir)") has no files, so the app would ship with no web assets.
                \(hint)
                """
            )
        }

        let entry = manifest.web.entry
        guard fm.fileExists(atPath: webDir.appendingPathComponent(entry).path) else {
            throw ValidationError(
                """
                web entry file not found: \(webDir.appendingPathComponent(entry).path)
                pwa.json's `web.entry` is "\(entry)", but that file isn't in `web.directory` ("\(dir)"). \
                The window opens this file on launch; without it it loads blank. Check the entry filename, \
                or set `web.entry` to your real entry point.
                """
            )
        }
    }
}
