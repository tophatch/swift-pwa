import Foundation
import SwiftPWACore

/// One of the app's own commands, resolved into the tool an agent would see.
struct ResolvedAgentTool: Equatable {
    /// The name the agent calls (`book.open` → `book_open`).
    let name: String
    /// The bridge command it maps onto.
    let command: String
    let description: String
    let inputSchema: BridgeJSON
    /// MCP tool annotations, or `nil` when the developer declared none.
    let annotations: BridgeJSON?

    /// The `tools/list` entry for this tool.
    var descriptor: BridgeJSON {
        var fields: [String: BridgeJSON] = [
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema
        ]
        if let annotations { fields["annotations"] = annotations }
        return .object(fields)
    }
}

/// Resolves `pwa.json`'s `agent.expose` list against an app's live command
/// catalog: the build-time half of Track B's two gates.
///
/// A stringly-typed allowlist has a failure mode worth designing out — a typo
/// exposes nothing and a rename silently *un*-exposes, both quietly. Since the
/// catalog is already available headlessly (`SWIFT_PWA_DESCRIBE`), the build can
/// check the list against reality and fail loud instead. For a security surface,
/// failing quiet is the worst available option.
///
/// Pure: manifest section + catalog in, tools and diagnostics out. No I/O, so
/// every rule below is unit-testable without building an app.
enum AgentPolicy {
    struct Resolution: Equatable {
        /// The tools an agent would be offered, in declaration order. Empty
        /// whenever `errors` isn't — a partial surface is not a safe one.
        var tools: [ResolvedAgentTool]
        /// Reasons the build should stop.
        var errors: [String]
        /// Things worth a second look that don't stop the build.
        var warnings: [String]

        var isEmpty: Bool {
            tools.isEmpty && errors.isEmpty && warnings.isEmpty
        }
    }

    /// Command namespaces that exist to hold something back, and so are refused
    /// rather than warned about.
    ///
    /// The line between this and ``systemPrefixes``: a warning says "you
    /// probably didn't mean this, but it's your app"; an error says there's no
    /// correct configuration of it. `secrets.*` is the latter because the risk
    /// annotations can't describe it honestly — `secrets.get` genuinely *is*
    /// read-only, so a consent sheet built from a developer's "Read a stored
    /// setting" would be accurate right up to the moment an agent walks off
    /// with the API key. The store exists so keys never enter JS; handing it to
    /// an agent is a wider hole than handing it to the page.
    ///
    /// The design rule this backs up is "expose the function, never the key":
    /// whatever needs a credential, the app does natively, and the key never
    /// crosses the tool boundary. An agent can't do anything with a key that a
    /// command couldn't do for it, and everything it *could* do is unbounded.
    ///
    /// Not a security boundary — a command that returns a credential looks like
    /// any other command and this can't see through it. It stops the careless
    /// case and makes intent explicit: doing the wrong thing takes deliberate
    /// code, not one string in a JSON file.
    ///
    /// `agent.*` is the other one, for a plainer reason: a tool that could call
    /// `agent.enable` would be able to widen its own access, which makes the
    /// user's gate decorative.
    /// Each carries its own explanation. One shared string covered both for a
    /// release, which meant an app declaring `agent.enable` was told the
    /// `secrets.*` story — that it would leak a credential — and pointed at a
    /// fix ("expose the command that uses the key") that has nothing to do with
    /// the actual problem. On the one surface where a developer is being told
    /// *no*, the reason has to be the real one.
    private static let forbiddenPrefixes: [(prefix: String, reason: String)] = [
        (
            "secrets.",
            """
            The `secrets.` namespace exists so credentials never leave the native side, and an agent that \
            can call it reads any key it can name — while the consent sheet, built from your description and \
            annotations, would honestly call that read-only. Whatever needs the key, your app should do: \
            expose the command that uses it (`myapp.translate`) so the key never crosses the tool boundary \
            at all.
            """
        ),
        (
            "agent.",
            """
            The `agent.` namespace is the user's gate over this whole surface, so a tool that could call it \
            would be able to widen its own access — and a gate an agent can open is decorative. Enabling \
            and revoking access stays with the user, through your app's own UI.
            """
        )
    ]

    /// Built-in system capabilities. Exposing one isn't wrong — it's the
    /// developer's app — but it's rarely what they meant: these are general
    /// primitives, so `fs.readText` gives an agent the *filesystem*, not a
    /// verb from the app's own vocabulary.
    private static let systemPrefixes = ["fs.", "process.", "net.", "clipboard.", "dialog."]

    static func resolve(_ section: PWAManifest.AgentSection?, against catalog: [CommandDescriptor]) -> Resolution {
        guard let entries = section?.expose, !entries.isEmpty else {
            return Resolution(tools: [], errors: [], warnings: [])
        }
        let commands = Dictionary(catalog.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        var tools: [ResolvedAgentTool] = []
        var errors: [String] = []
        var warnings: [String] = []
        var seenCommands: Set<String> = []
        var seenToolNames: Set<String> = []

        for entry in entries {
            let command = entry.command
            guard seenCommands.insert(command).inserted else {
                errors.append("agent.expose lists '\(command)' more than once.")
                continue
            }
            if command.hasPrefix("__") {
                errors.append("agent.expose can't expose '\(command)' — the `__` namespace is bridge internals.")
                continue
            }
            if let refused = forbiddenPrefixes.first(where: { command.hasPrefix($0.prefix) }) {
                errors.append("agent.expose can't expose '\(command)'. \(refused.reason)")
                continue
            }
            guard let descriptor = commands[command] else {
                errors.append("""
                agent.expose names '\(command)', which the app doesn't \
                register.\(suggestion(for: command, in: commands.keys))
                """)
                continue
            }
            guard descriptor.kind == .unary else {
                errors.append("""
                agent.expose names '\(command)', which is a \(descriptor.kind.rawValue) command. An MCP tool call \
                is one request and one result, so only unary commands can be exposed.
                """)
                continue
            }
            guard let inputSchema = JSONSchemaGenerator.toolInputSchema(for: descriptor.args) else {
                errors.append("""
                agent.expose names '\(command)', whose arguments aren't describable as a tool input. An MCP \
                inputSchema is an object, so the command needs either no arguments or a struct — a bare \
                value has no field name to give the agent, and an untyped payload has no shape at all. \
                Conform its args type to `BridgeType` if it isn't already.
                """)
                continue
            }
            let description = entry.description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !description.isEmpty else {
                errors.append("""
                agent.expose gives '\(command)' an empty description — that's what the agent reads to \
                decide whether to call it.
                """)
                continue
            }
            let toolName = entry.toolName ?? derivedToolName(for: command)
            guard isValidToolName(toolName) else {
                errors.append("""
                '\(command)' derives the tool name '\(toolName)', which isn't a valid MCP tool name \
                (letters, digits, `_` and `-`, up to 64 characters). Set `tool_name` explicitly.
                """)
                continue
            }
            guard seenToolNames.insert(toolName).inserted else {
                errors.append("""
                '\(command)' produces the tool name '\(toolName)', which another entry already uses. \
                Set `tool_name` to disambiguate.
                """)
                continue
            }
            if driverToolNames.contains(toolName) {
                errors.append("""
                '\(command)' produces the tool name '\(toolName)', which collides with a built-in driver tool. \
                Set `tool_name` to something else.
                """)
                continue
            }

            if let prefix = systemPrefixes.first(where: { command.hasPrefix($0) }) {
                warnings.append("""
                agent.expose includes '\(command)', a built-in `\(prefix)` capability rather than one of your \
                app's own verbs — an agent that can call it gets the general primitive, not the narrow thing \
                you had in mind. Prefer wrapping it in a command that does only what you intend.
                """)
            }
            if entry.readOnly == true, entry.destructive == true {
                warnings.append("""
                '\(command)' is annotated both read-only and destructive; an agent host will treat it \
                as destructive.
                """)
            }
            let untyped = untypedFields(in: descriptor.args)
            if !untyped.isEmpty {
                warnings.append("""
                '\(command)' has argument\(untyped.count == 1 ? "" : "s") with no schema (\(untyped
                    .joined(separator: ", "))). \
                The agent will be told they accept any JSON, which usually means guessing. Conform the field's \
                type to `BridgeType` to describe \(untyped.count == 1 ? "it" : "them").
                """)
            }

            tools.append(ResolvedAgentTool(
                name: toolName,
                command: command,
                description: description,
                inputSchema: inputSchema,
                annotations: annotations(for: entry)
            ))
        }

        // A partial surface is worse than none: the developer would see a build
        // that "worked" and ship an allowlist missing whatever failed.
        return Resolution(tools: errors.isEmpty ? tools : [], errors: errors, warnings: warnings)
    }

    // MARK: - Drift between the declaration and the binary

    /// Compare `pwa.json`'s declaration against the tool list actually compiled
    /// into the app (`AgentPlugin(tools:)`), which is what the runtime
    /// enforces.
    ///
    /// Two sources for one fact is normally a smell, and this is the price of
    /// the split that makes it worth it: `pwa.json` is *reviewable* — someone
    /// auditing what an app offers reads one JSON block, not a Swift file — and
    /// the compiled list is *enforceable*, since the runtime can't consult a
    /// manifest that isn't in the bundle. Drift between them would mean the
    /// reviewable copy stopped describing reality, so it fails the build.
    ///
    /// `nil` for `compiled` means the app installs no `AgentPlugin` at all,
    /// which is its own error when `pwa.json` declares tools: the developer
    /// wrote the ceiling and never wired it up.
    static func drift(declared: PWAManifest.AgentSection?, compiled: [AgentTool]?) -> [String] {
        let declaredEntries = declared?.expose ?? []
        guard !declaredEntries.isEmpty || !(compiled ?? []).isEmpty else { return [] }

        guard let compiled else {
            return ["""
            pwa.json declares \(declaredEntries.count) command\(declaredEntries.count == 1 ? "" : "s") under \
            `agent.expose`, but the app installs no AgentPlugin, so nothing is exposable at runtime. Add \
            `ctx.use(AgentPlugin(tools: [...]))` in configure with the same list.
            """]
        }

        var problems: [String] = []
        let declaredByCommand = Dictionary(
            declaredEntries.map { ($0.command, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let compiledByCommand = Dictionary(
            compiled.map { ($0.command, $0) }, uniquingKeysWith: { first, _ in first }
        )

        for command in Set(compiledByCommand.keys).subtracting(declaredByCommand.keys).sorted() {
            problems.append("""
            the app compiles in an agent tool for '\(command)', which pwa.json's agent.expose doesn't \
            declare. Anything the app can offer an agent has to be reviewable in pwa.json.
            """)
        }
        for command in Set(declaredByCommand.keys).subtracting(compiledByCommand.keys).sorted() {
            problems.append("""
            pwa.json's agent.expose declares '\(command)', which the app doesn't pass to AgentPlugin — so \
            it would never actually be offered. Add it to the tools list in configure.
            """)
        }
        for command in Set(declaredByCommand.keys).intersection(compiledByCommand.keys).sorted() {
            guard let declared = declaredByCommand[command], let built = compiledByCommand[command] else { continue }
            // The description and the risk annotations are what a user reads
            // before allowing access, so a mismatch there is exactly the kind
            // that matters: the reviewed copy would be describing something
            // else.
            if declared.description.trimmingCharacters(in: .whitespacesAndNewlines) != built.description {
                problems.append("'\(command)' is described differently in pwa.json and in the app's AgentPlugin.")
            }
            if declared.readOnly != built.readOnly || declared.destructive != built.destructive
                || declared.idempotent != built.idempotent || declared.openWorld != built.openWorld
            {
                problems.append("'\(command)' carries different risk annotations in pwa.json and in the app.")
            }
            if declared.toolName != built.toolName {
                problems.append("'\(command)' is named differently for the agent in pwa.json and in the app.")
            }
        }
        return problems
    }

    // MARK: - Tool naming

    /// `book.open` → `book_open`. Dots are the bridge's namespace separator and
    /// aren't in MCP's conventional name character set.
    static func derivedToolName(for command: String) -> String {
        String(command.map { $0 == "." ? "_" : $0 })
    }

    static func isValidToolName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    private static var driverToolNames: Set<String> {
        Set(MCPTools.all.map(\.name))
    }

    // MARK: - Annotations

    private static func annotations(for entry: PWAManifest.ExposedCommand) -> BridgeJSON? {
        var fields: [String: BridgeJSON] = [:]
        if let readOnly = entry.readOnly { fields["readOnlyHint"] = .bool(readOnly) }
        if let destructive = entry.destructive { fields["destructiveHint"] = .bool(destructive) }
        if let idempotent = entry.idempotent { fields["idempotentHint"] = .bool(idempotent) }
        if let openWorld = entry.openWorld { fields["openWorldHint"] = .bool(openWorld) }
        return fields.isEmpty ? nil : .object(fields)
    }

    // MARK: - Diagnostics

    /// Field paths inside an args schema that carry no type information.
    private static func untypedFields(in schema: BridgeSchema, path: String = "") -> [String] {
        switch schema {
        case .unknown:
            [path.isEmpty ? "(the whole payload)" : path]
        case let .optional(inner), let .array(inner), let .dictionary(inner):
            untypedFields(in: inner, path: path)
        case let .object(_, fields):
            fields.flatMap { untypedFields(in: $0.schema, path: path.isEmpty ? $0.name : "\(path).\($0.name)") }
        case .void, .bool, .int, .double, .string, .stringEnum:
            []
        }
    }

    /// "Did you mean …" for a misspelled command — the whole point of validating
    /// against the catalog is catching a rename, so name the likely candidate.
    private static func suggestion(for command: String, in known: some Collection<String>) -> String {
        let lowered = command.lowercased()
        // A rename usually keeps the namespace or the verb, so a shared prefix
        // or a case-insensitive match is a better signal here than edit distance.
        let candidates = known.filter { candidate in
            let other = candidate.lowercased()
            return other == lowered
                || other.hasPrefix(namespace(of: lowered))
                || lowered.hasPrefix(namespace(of: other))
        }
        guard !candidates.isEmpty else { return "" }
        // Closest first: a truncated list that omits the actual match would be
        // worse than no suggestion at all.
        let shown = candidates
            .sorted { (sharedPrefix($0, lowered), $1) > (sharedPrefix($1, lowered), $0) }
            .prefix(4)
        return " Registered command\(shown.count == 1 ? "" : "s") in that namespace: \(shown.joined(separator: ", "))."
    }

    private static func sharedPrefix(_ candidate: String, _ typo: String) -> Int {
        zip(candidate.lowercased(), typo).prefix { $0 == $1 }.count
    }

    private static func namespace(of command: String) -> String {
        guard let dot = command.lastIndex(of: ".") else { return command }
        return String(command[..<command.index(after: dot)])
    }
}
