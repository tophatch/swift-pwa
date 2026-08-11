import ArgumentParser
import Foundation

/// Single source of truth for the swift-pwa version string. Stamped into
/// the CLI's `--version` output so it matches the `SwiftPWA` library a
/// generated project resolves (both come from the same release). Bump
/// this in lockstep with the git tag / the `CHANGELOG.md` heading when
/// cutting a release — there's no SwiftPM hook to inject the package
/// version into a host-tool build, so it lives here by hand.
public enum SwiftPWAVersion {
    public static let current = "0.9.10"
}

/// Root command for the `swift-pwa` CLI. Lives in the
/// `SwiftPWACLISupport` library rather than the `swift-pwa-cli`
/// executable target so the test target can depend on the library
/// without dragging the executable's `main` entry point into its
/// link. (Swift on Windows otherwise emits an executable-level
/// `main` symbol that collides with the test runner's own `main`.)
///
/// `@available` annotation is required by SwiftArgumentParser when
/// the root command is `AsyncParsableCommand` — its runtime check
/// fires on platforms without a package-level minimum (Windows,
/// Linux), refusing to dispatch into an async `run()` without proof
/// that `_Concurrency` is available. The package's `platforms:` clause
/// already pins macOS / iOS above the bar; this annotation extends the
/// guarantee to the host-tools platforms the CLI also runs on.
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
public struct SwiftPWACLIRoot: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "swift-pwa",
        abstract: "Build, run, and bundle Swift-native PWA apps.",
        version: SwiftPWAVersion.current,
        subcommands: [
            Init.self, Dev.self, Build.self, Deploy.self, Drive.self, MCP.self, Updater.self, GenerateCI.self,
            Codegen.self, Agent.self,
            Doctor.self, SelfUpdate.self
        ],
        defaultSubcommand: nil
    )

    public init() {}
}

/// Availability-refined entry point for the `swift-pwa` executable.
///
/// SwiftArgumentParser ships two overloads of `main()` — a sync one
/// on `ParsableCommand` and an async one on `AsyncParsableCommand`,
/// the latter `@available(macOS 10.15, …, *)`-gated. Overload
/// resolution prefers the async one only inside a scope that
/// already satisfies that availability. On Apple targets the package
/// `platforms:` clause lifts the deployment target past 10.15, so a
/// bare `await SwiftPWACLIRoot.main()` in `main.swift` picks the
/// async overload. SwiftPM has no Windows / Linux deployment-target
/// concept, so on those hosts the same call site falls through to
/// the sync overload — at which point SAP's debug-mode runtime
/// check fires "Asynchronous root command needs availability
/// annotation" and the binary exits before reaching the build /
/// init / dev subcommand.
///
/// This wrapper is `@available`-annotated, so its body is a
/// refined scope where the async `main()` is unambiguously the
/// preferred overload regardless of host platform. `main.swift`
/// calls into here instead of touching `SwiftPWACLIRoot` directly.
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
public enum SwiftPWACLIEntry {
    public static func run() async {
        quietBareRepositoryGitWarning()
        await SwiftPWACLIRoot.main()
    }

    /// Stop SwiftPM's internal `git` calls (dependency resolution during
    /// `swift build` / `swift package describe`) from printing
    /// `warning: skipping cache … couldn't fetch updates` on machines that
    /// harden git with `safe.bareRepository = explicit`. SwiftPM's clone
    /// cache is a bare repo, and that hardening makes git refuse to operate
    /// on it, so the cache is skipped with a noisy warning on every build.
    ///
    /// We relax it for **our child processes only** via git's
    /// `GIT_CONFIG_*` environment protocol (git ≥ 2.31) — the equivalent of
    /// `git -c safe.bareRepository=all`. This never touches the user's git
    /// config files, only the environment inherited by the tools swift-pwa
    /// spawns. Skipped if the user already drives `GIT_CONFIG_*` themselves
    /// (don't clobber their setup).
    private static func quietBareRepositoryGitWarning() {
        // POSIX only. `setenv` isn't in scope on Windows (ucrt exposes
        // `_putenv_s`), and this warning is a Unix-y-hardening cosmetic —
        // not worth the CRT-import surface to suppress on Windows.
        #if !os(Windows)
            guard ProcessInfo.processInfo.environment["GIT_CONFIG_COUNT"] == nil else { return }
            setenv("GIT_CONFIG_COUNT", "1", 1)
            setenv("GIT_CONFIG_KEY_0", "safe.bareRepository", 1)
            setenv("GIT_CONFIG_VALUE_0", "all", 1)
        #endif
    }
}
