import ArgumentParser
import Foundation
import SwiftPWACore

/// Reads an app's bridge command catalog — the `[CommandDescriptor]` array
/// `CommandRegistry` produces — without a window or a devtools round-trip.
///
/// Shared by `swift-pwa codegen` (which turns it into a typed TS client) and the
/// `agent.expose` validation in `swift-pwa build` / `swift-pwa agent check`
/// (which checks the allowlist names commands that actually exist). Both need
/// the same thing: build the app, run it once with `SWIFT_PWA_DESCRIBE` pointed
/// at a temp file, decode what it wrote.
enum CommandCatalog {
    /// Build and run the app headlessly, returning its catalog.
    ///
    /// The app's `configure` closure runs for real (that's how dynamically
    /// named commands get captured), so it must be pure up to registration —
    /// `createWindow` is inert, but other side effects still fire. Apps guard
    /// such work with `HeadlessDescribe.isDumping`.
    /// A headless dump: the command catalog, plus the agent tool list the app
    /// compiled in (`nil` when it installs no `AgentPlugin`).
    struct Dump {
        let commands: [CommandDescriptor]
        let agentTools: [AgentTool]?
    }

    static func dump(
        projectRoot: URL,
        manifest: PWAManifest,
        configuration: String = "debug",
        quiet: Bool = false
    ) async throws -> [CommandDescriptor] {
        try await dumpAll(
            projectRoot: projectRoot, manifest: manifest, configuration: configuration, quiet: quiet
        ).commands
    }

    static func dumpAll(
        projectRoot: URL,
        manifest: PWAManifest,
        configuration: String = "debug",
        quiet: Bool = false
    ) async throws -> Dump {
        guard ["debug", "release"].contains(configuration) else {
            throw ValidationError("--configuration must be 'debug' or 'release', got '\(configuration)'.")
        }
        let fm = FileManager.default
        let exe = await ExecutableNameResolver.resolve(projectRoot: projectRoot, manifest: manifest)
        let catalogURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-catalog-\(exe).json")
        try? fm.removeItem(at: catalogURL)
        // Stale sidecar from a previous run would otherwise read as "the app
        // still compiles in an agent surface" after one was removed.
        try? fm.removeItem(at: URL(fileURLWithPath: catalogURL.path + HeadlessDescribe.agentCatalogSuffix))

        if !quiet {
            print("Building \(exe) (\(configuration)) for a headless catalog dump…")
        }
        // `swift run` builds then runs in one step. The app writes the catalog
        // to SWIFT_PWA_DESCRIBE and exits before opening a window; build/run
        // output is inherited so the user sees progress. Nothing we need rides
        // stdout — the catalog is the file.
        try await Shell.run(
            "/usr/bin/env",
            ["swift", "run", "-c", configuration, exe],
            cwd: projectRoot,
            envOverrides: [HeadlessDescribe.environmentVariable: catalogURL.path]
        )

        guard fm.fileExists(atPath: catalogURL.path) else {
            throw ValidationError("""
            The app ran but didn't write a catalog to \(catalogURL.path).
            The backend must call `HeadlessDescribe.dumpIfRequested` in `run` — it's built in for the \
            shipped backends, so this usually means a custom runtime, or the app exited in `configure` \
            before registration.
            """)
        }
        let agentURL = URL(fileURLWithPath: catalogURL.path + HeadlessDescribe.agentCatalogSuffix)
        let agentTools: [AgentTool]? = fm.contents(atPath: agentURL.path).flatMap {
            try? JSONDecoder().decode([AgentTool].self, from: $0)
        }
        return try Dump(commands: decode(at: catalogURL), agentTools: agentTools)
    }

    static func decode(at url: URL) throws -> [CommandDescriptor] {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ValidationError("Catalog not found: \(url.path)")
        }
        do {
            return try JSONDecoder().decode([CommandDescriptor].self, from: data)
        } catch {
            throw ValidationError("Couldn't parse \(url.path) as a [CommandDescriptor] JSON array: \(error)")
        }
    }
}
