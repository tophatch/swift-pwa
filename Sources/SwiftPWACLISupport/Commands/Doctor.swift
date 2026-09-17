import ArgumentParser
import Foundation

/// Prerequisite checker. Reports, per target, what's installed and what's
/// missing — with a copy-paste fix for each gap — so a build failure is a
/// friendly upfront message instead of a cryptic mid-compile toolchain
/// error. Run it directly (`swift-pwa doctor [--target ios]`) or lean on
/// `build`'s own preflight for the project-shape checks.
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check that the toolchains a target needs are installed.",
        discussion: """
        With no --target, checks the tools needed to build for this machine's platform. Pass \
        --target to check a specific one (e.g. `doctor --target ios`). Exits non-zero if a \
        required tool for the checked target is missing, so it's usable in scripts.
        """
    )

    @Option(
        help: "Target to check: \(BuildTarget.allCases.map(\.rawValue).joined(separator: ", ")). Defaults to the host."
    )
    var target: BuildTarget?

    /// One prerequisite check and its outcome.
    struct Check {
        let name: String
        let ok: Bool
        let detail: String
        let required: Bool
        let fix: String?
    }

    func run() async throws {
        let target = target ?? .host
        var checks: [Check] = await [Self.swiftToolchain()]
        checks += await Self.checks(for: target)
        // Project-level: flag a generated native shell that lags the CLI,
        // regardless of which target we're checking. No-op outside a project.
        checks += Self.scaffoldFreshness()
        checks += Self.audioPolicy()

        print("swift-pwa doctor — target: \(target.rawValue)\n")
        for check in checks {
            let mark = check.ok ? "✓" : (check.required ? "✗" : "•")
            print("  \(mark) \(check.name): \(check.detail)")
            if !check.ok, let fix = check.fix {
                print("      ↳ \(fix)")
            }
        }

        let missingRequired = checks.filter { !$0.ok && $0.required }
        print("")
        if missingRequired.isEmpty {
            print("All required tools for \(target.rawValue) are present. 🎉")
        } else {
            print("Missing \(missingRequired.count) required tool(s) for \(target.rawValue) — see the fixes above.")
            throw ExitCode.failure
        }
    }

    // MARK: - Quiet preflight (used by `build`)

    /// The *required* tools a target needs that are currently missing, as
    /// `(label, fix)` pairs. `build` calls this to emit one concise heads-up
    /// before a long compile — a quiet preflight that says nothing on a
    /// healthy machine, rather than the full `doctor` checklist. Excludes the
    /// advisory (non-required) checks and the scaffold-freshness pass, which
    /// `doctor` still surfaces in full.
    static func requiredToolGaps(for target: BuildTarget) async -> [(label: String, fix: String?)] {
        var checks: [Check] = await [swiftToolchain()]
        checks += await self.checks(for: target)
        return checks.filter { !$0.ok && $0.required }.map { ($0.name, $0.fix) }
    }

    // MARK: - Checks

    private static func swiftToolchain() async -> Check {
        #if os(Windows)
            // No `/usr/bin/env` on Windows — resolve `swift` on PATH via
            // where.exe, then read its --version. (Probing through /usr/bin/env
            // here made the Windows preflight always report the toolchain
            // "not found" even on a healthy VS Developer shell.)
            if let path = try? await Shell.capture("where.exe", ["swift"], timeout: 10, discardStderr: true),
               let exe = path.split(whereSeparator: \.isNewline).first.map(String.init),
               !exe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                let v = try? await Shell.capture(
                    exe.trimmingCharacters(in: .whitespacesAndNewlines), ["--version"],
                    timeout: 10, discardStderr: true
                )
                let line = v?.split(separator: "\n").first.map(String.init) ?? "installed"
                return Check(name: "Swift toolchain", ok: true, detail: line, required: true, fix: nil)
            }
        #else
            if let v = try? await Shell.capture(
                "/usr/bin/env",
                ["swift", "--version"],
                timeout: 10,
                discardStderr: true
            ) {
                let line = v.split(separator: "\n").first.map(String.init) ?? "installed"
                return Check(name: "Swift toolchain", ok: true, detail: line, required: true, fix: nil)
            }
        #endif
        return Check(
            name: "Swift toolchain", ok: false, detail: "not found",
            required: true, fix: "Install Swift 6+ from https://swift.org/install (or Xcode on macOS)."
        )
    }

    private static func checks(for target: BuildTarget) async -> [Check] {
        switch target {
        case .macos:
            return await [
                tool(
                    "codesign",
                    label: "codesign (signing)",
                    required: false,
                    fix: "Ships with the Xcode Command Line Tools: xcode-select --install"
                ),
                xcrun(
                    "iconutil",
                    label: "iconutil (app icon)",
                    required: false,
                    fix: "Ships with the Xcode Command Line Tools: xcode-select --install"
                )
            ]
        case .ios:
            return await [
                xcrun(
                    "xcodebuild",
                    label: "Xcode (xcodebuild)",
                    required: true,
                    fix: "Install Xcode from the App Store, then: sudo xcode-select -s /Applications/Xcode.app"
                ),
                xcrun(
                    "actool",
                    label: "actool (app icon)",
                    required: false,
                    fix: "Ships with Xcode. If it errors at build time, run: xcodebuild -runFirstLaunch"
                ),
                iosSimulatorRuntime(),
                iosCodeSigning()
            ]
        case .linux:
            return await [
                tool(
                    "linuxdeploy",
                    label: "linuxdeploy (AppImage)",
                    required: true,
                    fix: "Download linuxdeploy-x86_64.AppImage from github.com/linuxdeploy/linuxdeploy/releases and put it on PATH."
                ),
                zstdDeltaTool()
            ]
        case .windows:
            #if os(Windows)
                return await [
                    tool(
                        "link",
                        label: "MSVC linker (link.exe)",
                        required: true,
                        fix: "Run from a Visual Studio Developer prompt, or set up the MSVC environment."
                    ),
                    zstdDeltaTool()
                ]
            #else
                return [Check(
                    name: "Windows host", ok: false, detail: "Windows builds must run on a Windows machine",
                    required: true,
                    fix: "Run `swift-pwa build --target windows` on Windows, or use the generated GitHub Actions workflow."
                )]
            #endif
        case .android:
            var checks: [Check] = await [
                androidNDK(),
                androidSDK(),
                androidJDK(),
                androidSwiftSDK()
            ]
            if let match = await androidToolchainMatch() { checks.append(match) }
            if let drift = androidEntryDriftCheck() { checks.append(drift) }
            return checks
        }
    }

    /// Whether this host can actually compile against the Swift Android SDK
    /// it has installed.
    ///
    /// There is deliberately **no repo-wide Swift pin** for Android (see
    /// docs/android-setup.md §1): the installed SDK names the release it
    /// needs, and the CLI matches a toolchain to it — via `TOOLCHAINS` on a
    /// Mac, via `swiftly run +<release>` elsewhere. That policy is only
    /// friendly if a host missing the release says so *here*, rather than
    /// through "module compiled with Swift X cannot be imported by the Swift Y
    /// compiler" at the end of a multi-minute cross-compile.
    ///
    /// Advisory, not required, and `nil` when no Android SDK bundle is
    /// installed at all — the "Swift Android SDK" check above already reports
    /// that, and a second failure line reads as a second problem.
    private static func androidToolchainMatch() async -> Check? {
        guard let sdk = AndroidToolchain.installedAndroidSDK() else { return nil }
        let name = "Android SDK / toolchain match"
        guard let release = sdk.release else {
            return Check(
                name: name, ok: false,
                detail: "'\(sdk.bundle)' carries no Swift release in its name, so no toolchain can be "
                    + "matched to it",
                required: false,
                fix: "Set TOOLCHAINS (macOS) or wrap the build in `swiftly run +<release>` by hand "
                    + "— see docs/android-setup.md §1."
            )
        }
        #if os(macOS)
            if let toolchain = AndroidToolchain.releaseToolchainNames(matching: release).first {
                return Check(
                    name: name, ok: true,
                    detail: "\(sdk.bundle) needs Swift \(release) — \(toolchain) is installed",
                    required: false, fix: nil
                )
            }
            return Check(
                name: name, ok: false,
                detail: "\(sdk.bundle) needs Swift \(release), but no swift-\(release)-RELEASE*.xctoolchain "
                    + "is installed",
                required: false,
                // Xcode's Swift of the same number is a *different build* and
                // cannot load the SDK's prebuilt modules, so "you already have
                // 6.4 in Xcode" is not the answer here.
                fix: "Install the swift.org \(release) toolchain — Xcode's Swift of the same version is a "
                    + "different build and can't load the SDK's modules. See docs/android-setup.md §1."
            )
        #else
            let ambient = await AndroidBundler.ambientSwiftVersion()
            if ambient == release {
                return Check(
                    name: name, ok: true,
                    detail: "\(sdk.bundle) needs Swift \(release) — the ambient swift is \(release)",
                    required: false, fix: nil
                )
            }
            let ambientLabel = ambient ?? "unreadable"
            // swiftly being *present* isn't the question: `swiftly run
            // +<release>` fails outright when it has no such toolchain rather
            // than falling back, so ask it what it has.
            if let swiftly = AndroidBundler.locateSwiftly(), await swiftlyHasRelease(release, swiftly: swiftly) {
                return Check(
                    name: name, ok: true,
                    detail: "\(sdk.bundle) needs Swift \(release); the ambient swift is \(ambientLabel), so the "
                        + "cross-compile runs under `swiftly run +\(release)`",
                    required: false, fix: nil
                )
            }
            return Check(
                name: name, ok: false,
                detail: "\(sdk.bundle) needs Swift \(release), the ambient swift is \(ambientLabel), and "
                    + "swiftly has no \(release) toolchain to bridge them",
                required: false,
                fix: "swiftly install \(release).<patch> — name the SDK's own patch version, since "
                    + "`.swiftmodule` isn't ABI-stable across patches. See docs/android-setup.md §1."
            )
        #endif
    }

    #if !os(macOS)
        /// Whether `swiftly list` reports an installed toolchain on the
        /// `release` line. Its output is one toolchain per line, `Swift 6.4.0`
        /// or `Swift 6.4.0 (in use) (default)`.
        private static func swiftlyHasRelease(_ release: String, swiftly: String) async -> Bool {
            guard let output = try? await Shell.capture(swiftly, ["list"], timeout: 30, discardStderr: true)
            else { return false }
            return output.split(whereSeparator: \.isNewline).contains { swiftlyLine($0, isRelease: release) }
        }
    #endif

    /// Pure half of the `swiftly list` scan, so it is testable on every host:
    /// does this line name a toolchain in the `release` line? Matches
    /// `Swift 6.4` and `Swift 6.4.1 (in use)`, but not `Swift 6.40`.
    static func swiftlyLine(_ line: some StringProtocol, isRelease release: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("Swift \(release)") else { return false }
        let rest = trimmed.dropFirst("Swift \(release)".count)
        return rest.isEmpty || rest.first == "." || rest.first == " "
    }

    /// In an Android project, flag a stale JNI entry point — `package_id`
    /// changed after `init` but the hand-written `@_cdecl` in
    /// `AndroidEntry.swift` still names the old package, which is a
    /// guaranteed `UnsatisfiedLinkError` at launch. Returns `nil` outside a
    /// project, or when the symbol already matches (no news is good news).
    private static func androidEntryDriftCheck() -> Check? {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard let manifest = try? PWAManifest.load(from: cwd.appendingPathComponent("pwa.json")) else {
            return nil
        }
        let pkg = AndroidEntryDrift.resolvePackageId(manifest)
        guard let m = AndroidEntryDrift.detect(projectRoot: cwd, packageId: pkg) else { return nil }
        return Check(
            name: "Android JNI entry (\(m.file))",
            ok: false,
            detail: "declares Java_\(m.declared)_…, but package_id '\(pkg)' needs Java_\(m.expected)_… "
                + "(UnsatisfiedLinkError at launch)",
            required: true,
            fix: "Set the @_cdecl in \(m.file) to "
                + "Java_\(m.expected)_MainActivity_swiftPwaMain, or delete it and "
                + "`swift-pwa init <name> --in-place`."
        )
    }

    // MARK: - Scaffold freshness

    /// Flags a generated native shell (`Sources/<name>/App.swift`) that
    /// lags the running CLI. The shell carries a `// swift-pwa-generated:
    /// vX` stamp; a mismatch means template features the CLI now expects —
    /// e.g. the `PWA_DEV_SERVER` branch `swift-pwa dev` relies on — may be
    /// missing, which is exactly the kind of silent drift that turns into a
    /// mid-run crash. Best-effort and never *required* (a stale shell still
    /// builds): returns no checks when run outside a project.
    private static func scaffoldFreshness() -> [Check] {
        let fm = FileManager.default
        let sources = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Sources")
        guard let subdirs = try? fm.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil) else {
            return []
        }
        let current = SwiftPWAVersion.current
        var checks: [Check] = []
        for dir in subdirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let appSwift = dir.appendingPathComponent("App.swift")
            guard let source = try? String(contentsOf: appSwift, encoding: .utf8) else { continue }
            let rel = "Sources/\(dir.lastPathComponent)/App.swift"
            let regen = "Regenerate: delete \(rel) and run `swift-pwa init \(dir.lastPathComponent) --in-place` "
                + "(then review the git diff)."
            if let stamped = Self.stampedVersion(in: source) {
                if stamped == current {
                    checks.append(Check(
                        name: "Generated shell (\(rel))", ok: true,
                        detail: "generated by the current CLI (v\(current))", required: false, fix: nil
                    ))
                } else {
                    checks.append(Check(
                        name: "Generated shell (\(rel))", ok: false,
                        detail: "generated by v\(stamped); CLI is v\(current) — the template may have changed",
                        required: false, fix: regen
                    ))
                }
            } else {
                checks.append(Check(
                    name: "Generated shell (\(rel))", ok: false,
                    detail: "no version stamp — predates scaffold stamping; may lack the dev-server branch "
                        + "`swift-pwa dev` needs",
                    required: false, fix: regen
                ))
            }
        }
        return checks
    }

    /// Advisory: an app that plays audio and never names an audio session
    /// policy.
    ///
    /// That app works on the machine it was written on and stops the moment it
    /// is backgrounded on iOS, which the runtime also warns about — but only on
    /// a device that is already playing, and the adopters this catches are the
    /// ones who don't own the platform where it bites. So it is checked here
    /// too, where a developer can read it before shipping.
    ///
    /// **Advisory, never a failure**, and it names its evidence. The
    /// unavoidable false positive is a bundled framework that mentions
    /// `AudioContext` for code the app never reaches; printing the file it
    /// matched turns that from noise into something dismissed at a glance,
    /// which a bare "you might have an audio problem" never could.
    private static func audioPolicy() -> [Check] {
        audioPolicy(in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    }

    /// Split from the caller so a test can point it at a project it built,
    /// rather than at whatever directory the test runner happens to be in.
    static func audioPolicy(in root: URL) -> [Check] {
        guard let manifest = try? PWAManifest.load(from: root.appendingPathComponent("pwa.json")) else {
            return []
        }
        let webRoot = root.appendingPathComponent(manifest.web.directory)
        guard let sources = webSources(under: webRoot) else { return [] }

        // Deliberately narrow. `.play()` would match a video element, a WAAPI
        // animation and half the game loops on earth; these are the spellings
        // that only mean "this app makes sound".
        let audioSignals = ["AudioContext", "new Audio(", "<audio", "<video"]
        var evidence: (file: String, signal: String)?
        var declaresPolicy = false

        for (path, text) in sources {
            if text.contains("audioSession") { declaresPolicy = true }
            if evidence == nil, let signal = audioSignals.first(where: text.contains) {
                evidence = (path, signal)
            }
            if declaresPolicy, evidence != nil { break }
        }

        guard let found = evidence else { return [] }
        if declaresPolicy {
            return [Check(
                name: "Audio session policy", ok: true,
                detail: "the page sets navigator.audioSession.type", required: false, fix: nil
            )]
        }
        return [Check(
            name: "Audio session policy", ok: false,
            detail: "\(manifest.web.directory)/\(found.file) uses \(found.signal), "
                + "but nothing in the page sets navigator.audioSession.type",
            required: false,
            fix: "Audio with the default 'auto' policy stops when the app is backgrounded on iOS, and "
                + "requests no audio focus on Android, so the user's own music plays over it. Set "
                + "`navigator.audioSession.type` — 'playback' for something the user chose to listen to, "
                + "'ambient' for game or UI sound that should mix. See docs/javascript-api.md."
        )]
    }

    /// Text files under the web root, as `(relative path, contents)`. Bounded
    /// so `doctor` stays instant on a project whose `web/` is a build output:
    /// a huge file is read for its head only, since a bundler puts nothing
    /// meaningful past the first megabyte that isn't also in it.
    private static func webSources(under root: URL) -> [(String, String)]? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        let extensions: Set = ["html", "htm", "js", "mjs", "cjs", "jsx", "ts", "tsx", "svelte", "vue"]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }

        var out: [(String, String)] = []
        for case let url as URL in walker {
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let relative = url.path.hasPrefix(root.path + "/")
                ? String(url.path.dropFirst(root.path.count + 1))
                : url.lastPathComponent
            out.append((relative, text.count > 1_000_000 ? String(text.prefix(1_000_000)) : text))
            if out.count >= 2000 { break }
        }
        return out.isEmpty ? nil : out.sorted { $0.0 < $1.0 }
    }

    /// Extract the version from a `// swift-pwa-generated: vX.Y.Z` stamp,
    /// or `nil` if the source carries no stamp. Tolerates a missing `v`.
    static func stampedVersion(in source: String) -> String? {
        for line in source.split(separator: "\n") {
            guard let range = line.range(of: "swift-pwa-generated:") else { continue }
            var rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("v") { rest.removeFirst() }
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    // MARK: - Probes

    private static func tool(_ name: String, label: String, required: Bool, fix: String) async -> Check {
        if await onPath(name) {
            return Check(name: label, ok: true, detail: "found", required: required, fix: nil)
        }
        return Check(name: label, ok: false, detail: "not on PATH", required: required, fix: fix)
    }

    /// Whether `name` resolves on `PATH`. Windows has no `/usr/bin/env`, so a
    /// POSIX `env which` probe there fails for *every* tool — which made
    /// `doctor`/`build`'s Windows preflight falsely report present tools (Swift,
    /// link.exe) as missing. Use `where.exe` on Windows, `env which` elsewhere.
    private static func onPath(_ name: String) async -> Bool {
        #if os(Windows)
            let out = try? await Shell.capture("where.exe", [name], timeout: 10, discardStderr: true)
        #else
            let out = try? await Shell.capture("/usr/bin/env", ["which", name], timeout: 10, discardStderr: true)
        #endif
        return out?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// Advisory: the `zstd` CLI backs `swift-pwa updater manifest --delta`
    /// (and `updater diff` / `patch`) — delta (binary-patch) updates on the
    /// Linux AppImage + Windows portable backends. Only needed when publishing
    /// deltas, so non-required (a `•`, never a build blocker).
    private static func zstdDeltaTool() async -> Check {
        await tool(
            "zstd",
            label: "zstd (delta updates)",
            required: false,
            fix: "Optional — only for `swift-pwa updater manifest --delta` (binary-patch updates). "
                + "Install: apt install zstd · brew install zstd · choco install zstandard."
        )
    }

    private static func xcrun(_ name: String, label: String, required: Bool, fix: String) async -> Check {
        if let path = try? await Shell.capture("/usr/bin/env", ["xcrun", "-f", name], timeout: 10, discardStderr: true),
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return Check(name: label, ok: true, detail: "found", required: required, fix: nil)
        }
        return Check(name: label, ok: false, detail: "not found", required: required, fix: fix)
    }

    private static func envDir(_ key: String, label: String, required: Bool, fix: String) async -> Check {
        if let path = ProcessInfo.processInfo.environment[key],
           FileManager.default.fileExists(atPath: path)
        {
            return Check(name: label, ok: true, detail: path, required: required, fix: nil)
        }
        return Check(name: label, ok: false, detail: "$\(key) unset or missing", required: required, fix: fix)
    }

    private static func iosSimulatorRuntime() async -> Check {
        let json = await (try? Shell.capture(
            "/usr/bin/env",
            ["xcrun", "simctl", "list", "runtimes", "-j"],
            timeout: 10,
            discardStderr: true
        )) ?? ""
        let runtimes = (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
            .flatMap { $0 as? [String: Any] }?["runtimes"] as? [[String: Any]]
        let hasIOS = runtimes?.contains {
            ($0["isAvailable"] as? Bool == true) && (($0["name"] as? String)?.hasPrefix("iOS ") == true)
        } ?? false
        return Check(
            name: "iOS Simulator runtime", ok: hasIOS,
            detail: hasIOS ? "installed" : "none (only needed for --simulator)",
            required: false,
            fix: "Install via Xcode → Settings → Platforms → iOS, or: xcodebuild -downloadPlatform iOS"
        )
    }

    /// A valid Apple Development / Distribution code-signing identity is
    /// needed only for **device** installs (simulator builds skip signing),
    /// so this is advisory. `security find-identity -v` lists *valid*
    /// identities only — a cert whose chain is broken (the classic missing
    /// Apple WWDR intermediate) simply won't appear, so the fix covers both
    /// "no cert" and "cert present but untrusted".
    private static func iosCodeSigning() async -> Check {
        let label = "iOS code-signing identity"
        let fix = """
        Only needed for device installs. Create an Apple Development certificate (Xcode → \
        Settings → Accounts, or developer.apple.com). If you have a cert but it isn't listed, \
        the Apple WWDR intermediate is likely missing — download it from \
        https://www.apple.com/certificateauthority/ and run: security import AppleWWDRCAG3.cer
        """
        let out = await (try? Shell.capture(
            "/usr/bin/env",
            ["security", "find-identity", "-v", "-p", "codesigning"],
            timeout: 10,
            discardStderr: true
        )) ?? ""
        let hasIdentity = ["Apple Development", "Apple Distribution", "iPhone Developer", "iPhone Distribution"]
            .contains { out.contains($0) }
        return Check(
            name: label, ok: hasIdentity,
            detail: hasIdentity ? "valid identity present" : "none found (only needed for device installs)",
            required: false,
            fix: hasIdentity ? nil : fix
        )
    }

    // The three host-toolchain pieces an Android build needs, reported through
    // `AndroidToolchain`'s discovery — so a standard install with no env vars
    // exported reads as ✓ (it builds), and the detail line says *where* each
    // piece was found, which is what you actually want on a machine carrying
    // three JDKs.

    private static func androidNDK() async -> Check {
        guard let ndk = AndroidToolchain.ndk() else {
            return Check(
                name: "Android NDK", ok: false, detail: "not found",
                required: true,
                fix: "Install NDK r27+ (Android Studio → SDK Manager, or the standalone download) "
                    + "and, if it isn't under the SDK, set ANDROID_NDK_HOME."
            )
        }
        // Missing `llvm-strip` isn't fatal, but it's the difference between a
        // 74 MB and a 130 MB APK — worth naming here rather than in a build log.
        let strip = AndroidToolchain.ndkTool("llvm-strip", ndk: ndk.path)
        let detail = strip == nil ? "\(ndk.origin) — no llvm-strip; .so files ship unstripped" : ndk.origin
        return Check(name: "Android NDK", ok: true, detail: detail, required: true, fix: nil)
    }

    private static func androidSDK() async -> Check {
        guard let sdk = AndroidToolchain.sdk() else {
            return Check(
                name: "Android SDK (Gradle)", ok: false, detail: "not found",
                required: true,
                fix: "Install the SDK (Android Studio, or the command-line tools) and set ANDROID_HOME, "
                    + "or put it in the standard location (macOS: ~/Library/Android/sdk, Linux: ~/Android/Sdk)."
            )
        }
        return Check(name: "Android SDK (Gradle)", ok: true, detail: sdk.origin, required: true, fix: nil)
    }

    /// Not a PATH probe: macOS ships a `/usr/bin/java` stub that satisfies
    /// `which java` with no JDK installed, which made this check pass on a
    /// machine where Gradle then died with "Unable to locate a Java Runtime".
    private static func androidJDK() async -> Check {
        let label = "JDK (Gradle)"
        switch await AndroidToolchain.resolveJava() {
        case .ambient:
            let detail = AndroidToolchain.jdk().map(\.origin) ?? "on PATH"
            return Check(name: label, ok: true, detail: detail, required: true, fix: nil)
        case let .discovered(jdk):
            // Usable — `deploy` points Gradle at it — but a by-hand
            // `./gradlew` in the staged project would still fail, so say so.
            return Check(
                name: label, ok: true,
                detail: "\(jdk.path) (not on PATH; deploy sets JAVA_HOME for Gradle)",
                required: true, fix: nil
            )
        case .missing:
            return Check(
                name: label, ok: false, detail: "no Java runtime found",
                required: true,
                fix: "Install JDK 17 so ./gradlew can run — macOS: `brew install openjdk@17`; "
                    + "Linux: `apt install openjdk-17-jdk`. Android Studio's bundled JBR counts too."
            )
        }
    }

    private static func androidSwiftSDK() async -> Check {
        let list = await (try? Shell.capture(
            "/usr/bin/env",
            ["swift", "sdk", "list"],
            timeout: 10,
            discardStderr: true
        )) ?? ""
        let hasAndroid = list.lowercased().contains("android")
        return Check(
            name: "Swift Android SDK", ok: hasAndroid,
            detail: hasAndroid ? "installed" : "not installed (needed for --cross-compile-android)",
            required: false,
            fix: "Install per docs/android-setup.md (swift sdk install <swift-android-sdk artifactbundle>)."
        )
    }
}
