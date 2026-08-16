import ArgumentParser
import Foundation
import SwiftPWACore

/// `swift-pwa agent` — inspect and validate the agent-facing tool surface an
/// app declares in `pwa.json`'s `agent.expose`.
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Agent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Validate and inspect the commands this app may expose to an AI agent.",
        subcommands: [AgentCheck.self],
        defaultSubcommand: AgentCheck.self
    )
}

/// `swift-pwa agent check` — resolve `agent.expose` against the app's live
/// command catalog and fail on anything that doesn't line up.
///
/// This is the developer's gate: a reviewable list in `pwa.json` that bounds
/// what the app *may* offer an agent. It exposes nothing on its own — the user
/// still has to turn exposure on inside the running app.
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct AgentCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check pwa.json's agent.expose against the app's registered commands.",
        discussion: """
        Builds the app and reads its command catalog headlessly (SWIFT_PWA_DESCRIBE), then checks every \
        exposed command exists, is callable as a tool, and is described. A typo would otherwise expose \
        nothing and a rename would silently un-expose — both quietly, which is the worst failure mode a \
        security surface can have. `swift-pwa build` runs this automatically when the target's binary \
        runs on the build host.
        """
    )

    @Option(help: "Path to pwa.json. Defaults to ./pwa.json.")
    var manifest: String = "pwa.json"

    @Option(
        name: .long,
        help: "Read a pre-captured `__bridge.describe` catalog JSON instead of building+running the app."
    )
    var catalog: String?

    @Option(help: "Build configuration for the headless dump: debug (default) or release.")
    var configuration: String = "debug"

    @Flag(help: "Print the resolved tools as the JSON an agent would be sent.")
    var json: Bool = false

    func run() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let pwa = try PWAManifest.load(from: cwd.appendingPathComponent(manifest))

        guard let expose = pwa.agent?.expose, !expose.isEmpty else {
            print("""
            No agent surface declared. Add an `agent.expose` list to pwa.json to make some of this app's \
            commands eligible for an agent; without it the app exposes nothing.
            """)
            return
        }

        let dump: CommandCatalog.Dump = if let catalog {
            // A pre-captured catalog carries no compiled surface, so the drift
            // check is skipped rather than reported as "the app has none".
            try CommandCatalog.Dump(
                commands: CommandCatalog.decode(at: URL(fileURLWithPath: catalog)),
                agentTools: nil,
                declaredPermissions: []
            )
        } else {
            try await CommandCatalog.dumpAll(projectRoot: cwd, manifest: pwa, configuration: configuration)
        }

        let resolution = AgentPolicy.resolve(pwa.agent, against: dump.commands)
        try AgentCheck.report(resolution, appName: pwa.name)
        if catalog == nil {
            try AgentCheck.reportDrift(AgentPolicy.drift(declared: pwa.agent, compiled: dump.agentTools))
        }

        if json {
            let tools = BridgeJSON.array(resolution.tools.map(\.descriptor))
            print(tools.prettyPrinted)
        }
    }

    /// Prints warnings, then throws on the first sign of an invalid surface.
    /// Shared with `swift-pwa build`, which runs the same check inline.
    static func report(_ resolution: AgentPolicy.Resolution, appName: String) throws {
        for warning in resolution.warnings {
            print("swift-pwa: warning: \(warning)")
        }
        guard resolution.errors.isEmpty else {
            throw ValidationError("""
            pwa.json's agent.expose doesn't match \(appName)'s registered commands:

            \(resolution.errors.map { "  • \($0)" }.joined(separator: "\n"))
            """)
        }
        let tools = resolution.tools
        print("""
        agent.expose: \(tools.count) tool\(tools.count == 1 ? "" : "s") eligible — \(summary(of: tools)).
        """)
    }

    /// Fail when the reviewable declaration and the compiled surface disagree.
    static func reportDrift(_ problems: [String]) throws {
        guard !problems.isEmpty else { return }
        throw ValidationError("""
        pwa.json's agent.expose and the app's compiled AgentPlugin disagree:

        \(problems.map { "  • \($0)" }.joined(separator: "\n"))

        pwa.json is the copy a reviewer reads; the compiled list is the one the runtime enforces. They \
        have to say the same thing.
        """)
    }

    /// The same risk breakdown an app's consent sheet should show the user, so
    /// the developer sees at build time what they'll be asking people to allow.
    private static func summary(of tools: [ResolvedAgentTool]) -> String {
        var readOnly = 0
        var destructive = 0
        for tool in tools {
            let hints = tool.annotations
            if hints?["destructiveHint"] == .bool(true) {
                destructive += 1
            } else if hints?["readOnlyHint"] == .bool(true) {
                readOnly += 1
            }
        }
        let other = tools.count - readOnly - destructive
        var parts: [String] = []
        if readOnly > 0 { parts.append("\(readOnly) read-only") }
        if destructive > 0 { parts.append("\(destructive) destructive") }
        if other > 0 { parts.append("\(other) unannotated") }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }
}
