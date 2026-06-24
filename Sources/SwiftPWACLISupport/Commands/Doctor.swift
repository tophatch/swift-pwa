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

    // MARK: - Checks

    private static func swiftToolchain() async -> Check {
        if let v = try? await Shell.capture("/usr/bin/env", ["swift", "--version"], timeout: 10, discardStderr: true) {
            let line = v.split(separator: "\n").first.map(String.init) ?? "installed"
            return Check(name: "Swift toolchain", ok: true, detail: line, required: true, fix: nil)
        }
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
                iosSimulatorRuntime()
            ]
        case .linux:
            return await [
                tool(
                    "linuxdeploy",
                    label: "linuxdeploy (AppImage)",
                    required: true,
                    fix: "Download linuxdeploy-x86_64.AppImage from github.com/linuxdeploy/linuxdeploy/releases and put it on PATH."
                )
            ]
        case .windows:
            #if os(Windows)
                return await [tool(
                    "link",
                    label: "MSVC linker (link.exe)",
                    required: true,
                    fix: "Run from a Visual Studio Developer prompt, or set up the MSVC environment."
                )]
            #else
                return [Check(
                    name: "Windows host", ok: false, detail: "Windows builds must run on a Windows machine",
                    required: true,
                    fix: "Run `swift-pwa build --target windows` on Windows, or use the generated GitHub Actions workflow."
                )]
            #endif
        case .android:
            return await [
                envDir(
                    "ANDROID_NDK_HOME",
                    label: "Android NDK",
                    required: true,
                    fix: "Install NDK r27+ and: export ANDROID_NDK_HOME=/path/to/android-ndk"
                ),
                tool(
                    "java",
                    label: "JDK (Gradle)",
                    required: true,
                    fix: "Install JDK 17 (e.g. Temurin) so ./gradlew can run."
                ),
                androidSwiftSDK()
            ]
        }
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
        if await (try? Shell.capture("/usr/bin/env", ["which", name], timeout: 10, discardStderr: true))
            .map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true
        {
            return Check(name: label, ok: true, detail: "found", required: required, fix: nil)
        }
        return Check(name: label, ok: false, detail: "not on PATH", required: required, fix: fix)
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
