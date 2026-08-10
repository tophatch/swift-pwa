import Foundation
import Testing

/// Guards against re-introducing a bug that has now landed three times: launching
/// a tool as `/usr/bin/env <tool>` from a code path that also runs on **Windows**,
/// where `/usr/bin/env` doesn't exist. The failure is nasty out of proportion to
/// the cause — `Process` reports a Foundation error that names no file at all
/// (`Code=260 "The file doesn't exist."`), so it reads as a mystery rather than a
/// missing launcher, and one of the three call sites swallowed it entirely and
/// silently degraded instead.
///
/// The history: `Doctor`'s tool probe (reported every present tool as missing on
/// Windows), then `swift-pwa drive` and `agent check` / `codegen` (both dead on
/// arrival on Windows for the whole 0.9.4–0.9.5 window).
///
/// `Shell.resolveExecutable` already does the right thing on every platform —
/// pass a **bare tool name** and it searches `PATH`, adding `.exe` / `.cmd` /
/// `.bat` on Windows. On POSIX that resolves to exactly what `env` would have
/// found, so there is no reason to name the launcher explicitly.
///
/// CI cannot catch this class of bug: the Windows job compiles and link-checks
/// but never launches an app, and `swift test` doesn't run on Windows at all
/// (swift-testing discovery emits 0-byte stubs). So this test is the guard, and
/// it deliberately runs off-Windows.
///
/// It is an **allowlist snapshot**, not a ban: plenty of call sites are genuinely
/// POSIX-only (`xcrun`, `codesign`, `security`, `iconutil`, `linuxdeploy`) and
/// `env` is fine there. Adding a new file to the list is a one-line change — the
/// point is that it can't happen *without noticing*.
@Suite("POSIX launcher hygiene")
struct EnvLauncherHygieneTests {
    /// Files permitted to name `/usr/bin/env`, each because it is unreachable on
    /// Windows or explicitly branches for it.
    private static let allowed: Set<String> = [
        // macOS-only toolchains: xcrun, codesign, security, iconutil, open, sips.
        "IPABundler.swift",
        "MacAppBundler.swift",
        "IconConverter.swift",
        "PersonalTeamProfileMinter.swift",
        "IOSSigning.swift",
        "IOSDeviceResolver.swift",
        "Deploy.swift",
        // Linux-only: linuxdeploy / appimagetool.
        "AppImageBundler.swift",
        // Android cross-compilation is supported from POSIX hosts only.
        "AndroidBundler.swift",
        // Both carry an explicit `#if os(Windows)` branch (where.exe).
        "Doctor.swift",
        "Dev.swift",
        // `process.*` is desktop POSIX; Windows returns E_UNIMPLEMENTED.
        "SystemProcess.swift"
    ]

    /// The *string literal*, quotes included — so prose about this bug (including
    /// the comments the fixes left behind, and this file) doesn't trip the check.
    /// Assembled at runtime to keep the literal itself out of the haystack.
    private static let literal = "\"" + "/usr/bin/env" + "\""

    private static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath) // …/Tests/SwiftPWACLITests/<this>.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    @Test("no new `/usr/bin/env` launchers outside the POSIX-only allowlist")
    func noUnexpectedEnvLaunchers() throws {
        let fm = FileManager.default
        let root = Self.sourcesDirectory
        let enumerator = try #require(fm.enumerator(at: root, includingPropertiesForKeys: nil))

        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let source = try? String(contentsOf: url, encoding: .utf8),
                  source.contains(Self.literal)
            else { continue }
            let name = url.lastPathComponent
            if !Self.allowed.contains(name) {
                offenders.append(name)
            }
        }

        #expect(
            offenders.isEmpty,
            """
            \(offenders.sorted().joined(separator: ", ")) launches a tool via `/usr/bin/env`, \
            which does not exist on Windows.

            If this code can run on Windows, pass the bare tool name instead — \
            `Shell.run("swift", ["build"])` — and `Shell.resolveExecutable` will find it \
            on every platform. If it genuinely cannot run on Windows, add the file to \
            `EnvLauncherHygieneTests.allowed` with the reason.
            """
        )
    }

    /// The allowlist is only meaningful if it stays pruned — a stale entry quietly
    /// re-opens the hole it was documenting.
    @Test("every allowlist entry still names `/usr/bin/env`")
    func allowlistHasNoStaleEntries() throws {
        let fm = FileManager.default
        let root = Self.sourcesDirectory
        let enumerator = try #require(fm.enumerator(at: root, includingPropertiesForKeys: nil))

        var seen: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            if let source = try? String(contentsOf: url, encoding: .utf8),
               source.contains(Self.literal)
            {
                seen.insert(url.lastPathComponent)
            }
        }

        let stale = Self.allowed.subtracting(seen).sorted()
        #expect(
            stale.isEmpty,
            "\(stale.joined(separator: ", ")) no longer uses `/usr/bin/env` — remove from the allowlist."
        )
    }
}
