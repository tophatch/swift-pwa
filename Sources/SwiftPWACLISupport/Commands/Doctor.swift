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
    private struct Check {
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
            if let drift = androidEntryDriftCheck() { checks.append(drift) }
            return checks
        }
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
