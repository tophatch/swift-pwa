import Foundation
@testable import SwiftPWACLISupport
import SwiftPWACore
import Testing

/// The developer-side gate of the agent surface: `pwa.json`'s `agent.expose`
/// resolved against the app's real command catalog. Pure input → output, so the
/// whole rule set is checkable without building an app.
@Suite("agent.expose validation")
struct AgentPolicyTests {
    // MARK: - Fixtures

    /// A small catalog standing in for an app's own vocabulary.
    static let catalog: [CommandDescriptor] = [
        CommandDescriptor(
            name: "book.open",
            kind: .unary,
            args: .object(name: "OpenBookArgs", fields: [
                BridgeField(name: "id", schema: .string),
                BridgeField(name: "page", schema: .optional(.int))
            ]),
            result: .void
        ),
        CommandDescriptor(name: "book.list", kind: .unary, args: .void, result: .array(.string)),
        CommandDescriptor(name: "book.delete", kind: .unary, args: .object(name: "DeleteArgs", fields: [
            BridgeField(name: "id", schema: .string)
        ]), result: .void),
        CommandDescriptor(name: "book.watch", kind: .stream, args: .void, result: .string),
        CommandDescriptor(name: "book.edit", kind: .session, args: .void, result: .string, inbound: .string),
        CommandDescriptor(name: "book.raw", kind: .unary, args: .string, result: .void),
        CommandDescriptor(name: "book.import", kind: .unary, args: .object(name: "ImportArgs", fields: [
            BridgeField(name: "payload", schema: .unknown)
        ]), result: .void),
        CommandDescriptor(name: "secrets.get", kind: .unary, args: .object(name: "SecretArgs", fields: [
            BridgeField(name: "key", schema: .string)
        ]), result: .void),
        CommandDescriptor(name: "fs.readText", kind: .unary, args: .object(name: "ReadArgs", fields: [
            BridgeField(name: "path", schema: .string)
        ]), result: .string),
        CommandDescriptor(name: "__bridge.describe", kind: .unary, args: .void, result: .unknown)
    ]

    static func section(_ entries: PWAManifest.ExposedCommand...) -> PWAManifest.AgentSection {
        PWAManifest.AgentSection(expose: entries)
    }

    static func expose(
        _ command: String,
        description: String = "Does a thing.",
        readOnly: Bool? = nil,
        destructive: Bool? = nil,
        toolName: String? = nil
    ) -> PWAManifest.ExposedCommand {
        PWAManifest.ExposedCommand(
            command: command,
            description: description,
            readOnly: readOnly,
            destructive: destructive,
            toolName: toolName
        )
    }

    static func resolve(_ section: PWAManifest.AgentSection?) -> AgentPolicy.Resolution {
        AgentPolicy.resolve(section, against: catalog)
    }

    static func minimalManifest() throws -> PWAManifest {
        let json = """
        {
          "id": "com.example.books", "name": "Books", "version": "1.0.0",
          "web": { "directory": "web", "entry": "index.html" },
          "window": { "title": "Books", "width": 800, "height": 600, "resizable": true, "fullscreen": false }
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PWAManifest.self, from: Data(json.utf8))
    }

    // MARK: - Nothing declared

    @Test("an app with no agent section exposes nothing, silently")
    func noSectionIsNotAnError() {
        #expect(Self.resolve(nil).isEmpty)
        #expect(Self.resolve(PWAManifest.AgentSection(expose: [])).isEmpty)
    }

    // MARK: - The happy path

    @Test("an exposed command becomes a tool with a derived name and its schema")
    func resolvesATool() throws {
        let resolution = Self.resolve(Self.section(
            Self.expose("book.open", description: "Open a book by id.", readOnly: true)
        ))
        #expect(resolution.errors.isEmpty)
        let tool = try #require(resolution.tools.first)
        #expect(tool.name == "book_open") // dots aren't in MCP's name character set
        #expect(tool.command == "book.open")
        #expect(tool.description == "Open a book by id.")
        #expect(tool.annotations == .object(["readOnlyHint": .bool(true)]))
        #expect(tool.inputSchema["type"] == .string("object"))
        #expect(tool.inputSchema["properties"]?["id"]?["type"] == .string("string"))
        // `page` is optional, so it's described but not required.
        #expect(tool.inputSchema["properties"]?["page"]?["type"] == .string("integer"))
        #expect(tool.inputSchema["required"] == .array([.string("id")]))
    }

    @Test("a no-argument command gets an empty object schema, as MCP requires")
    func voidArgsBecomeAnEmptyObject() throws {
        let resolution = Self.resolve(Self.section(Self.expose("book.list")))
        let tool = try #require(resolution.tools.first)
        #expect(tool.inputSchema["type"] == .string("object"))
        #expect(tool.inputSchema["properties"] == .object([:]))
    }

    @Test("a command with no annotations gets none, rather than invented defaults")
    func annotationsAreOptional() throws {
        let tool = try #require(Self.resolve(Self.section(Self.expose("book.list"))).tools.first)
        #expect(tool.annotations == nil)
    }

    @Test("the descriptor carries everything tools/list needs")
    func descriptorShape() throws {
        let tool = try #require(
            Self.resolve(Self.section(Self.expose("book.delete", destructive: true))).tools.first
        )
        let descriptor = tool.descriptor
        #expect(descriptor["name"] == .string("book_delete"))
        #expect(descriptor["description"] != nil)
        #expect(descriptor["inputSchema"]?["type"] == .string("object"))
        #expect(descriptor["annotations"]?["destructiveHint"] == .bool(true))
    }

    // MARK: - The point of the exercise: names that don't line up

    @Test("a command the app doesn't register fails, and names its siblings")
    func unknownCommandFails() throws {
        let resolution = Self.resolve(Self.section(Self.expose("book.opne")))
        #expect(resolution.tools.isEmpty)
        let error = try #require(resolution.errors.first)
        #expect(error.contains("book.opne"))
        // The whole reason to validate against the catalog is catching a rename,
        // so the message has to point at what does exist.
        #expect(error.contains("book.open"))
    }

    @Test("one bad entry invalidates the whole surface, not just itself")
    func partialSurfacesAreRefused() {
        let resolution = Self.resolve(Self.section(
            Self.expose("book.open"),
            Self.expose("book.nope")
        ))
        #expect(resolution.errors.count == 1)
        // Shipping the entries that happened to resolve would look like success
        // while quietly dropping whatever failed.
        #expect(resolution.tools.isEmpty)
    }

    @Test("listing the same command twice fails")
    func duplicateCommandFails() {
        let resolution = Self.resolve(Self.section(Self.expose("book.open"), Self.expose("book.open")))
        #expect(resolution.errors.contains { $0.contains("more than once") })
    }

    @Test("two entries that derive the same tool name fail")
    func duplicateToolNameFails() {
        let resolution = Self.resolve(Self.section(
            Self.expose("book.open"),
            Self.expose("book.list", toolName: "book_open")
        ))
        #expect(resolution.errors.contains { $0.contains("already uses") })
    }

    @Test("a tool name that collides with a built-in driver tool fails")
    func driverCollisionFails() {
        let resolution = Self.resolve(Self.section(Self.expose("book.open", toolName: "app_click")))
        #expect(resolution.errors.contains { $0.contains("built-in driver tool") })
    }

    @Test("a tool name MCP hosts won't accept fails")
    func invalidToolNameFails() {
        let resolution = Self.resolve(Self.section(Self.expose("book.open", toolName: "book open!")))
        #expect(resolution.errors.contains { $0.contains("valid MCP tool name") })
    }

    @Test("an empty description fails — it's what the agent reads to choose")
    func emptyDescriptionFails() {
        let resolution = Self.resolve(Self.section(Self.expose("book.open", description: "   ")))
        #expect(resolution.errors.contains { $0.contains("empty description") })
    }

    // MARK: - Shapes that can't be a tool

    @Test("streaming and duplex commands can't be tools", arguments: ["book.watch", "book.edit"])
    func nonUnaryFails(command: String) {
        let resolution = Self.resolve(Self.section(Self.expose(command)))
        #expect(resolution.errors.contains { $0.contains("only unary commands") })
    }

    @Test("a command whose arguments aren't an object can't be a tool")
    func nonObjectArgsFail() {
        let resolution = Self.resolve(Self.section(Self.expose("book.raw")))
        #expect(resolution.errors.contains { $0.contains("aren't describable as a tool input") })
    }

    // MARK: - Namespaces that hold something back

    @Test("the secret store can never be exposed")
    func secretsAreForbidden() {
        let resolution = Self.resolve(Self.section(Self.expose("secrets.get")))
        #expect(resolution.tools.isEmpty)
        let error = try? #require(resolution.errors.first { $0.contains("secrets.get") })
        #expect(error?.contains("credentials never leave the native side") == true)
    }

    @Test("bridge internals can never be exposed")
    func bridgeInternalsAreForbidden() {
        let resolution = Self.resolve(Self.section(Self.expose("__bridge.describe")))
        #expect(resolution.errors.contains { $0.contains("bridge internals") })
    }

    // MARK: - Warnings

    @Test("exposing a built-in system primitive warns but is allowed — it's the developer's app")
    func systemPrimitiveWarns() {
        let resolution = Self.resolve(Self.section(Self.expose("fs.readText")))
        #expect(resolution.errors.isEmpty)
        #expect(resolution.tools.count == 1)
        #expect(resolution.warnings.contains { $0.contains("fs.") })
    }

    @Test("contradictory annotations warn")
    func contradictoryAnnotationsWarn() {
        let resolution = Self.resolve(
            Self.section(Self.expose("book.delete", readOnly: true, destructive: true))
        )
        #expect(resolution.errors.isEmpty)
        #expect(resolution.warnings.contains { $0.contains("read-only and destructive") })
    }

    @Test("an argument with no schema warns, naming the field")
    func untypedFieldWarns() {
        let resolution = Self.resolve(Self.section(Self.expose("book.import")))
        #expect(resolution.errors.isEmpty)
        #expect(resolution.warnings.contains { $0.contains("payload") })
    }

    // MARK: - The build hook

    @Test("a cross-compiled build skips the check instead of failing or building")
    func crossCompiledBuildSkipsValidation() async throws {
        var manifest = try Self.minimalManifest()
        manifest.agent = Self.section(Self.expose("book.open"))
        // Android is never the build host. Validating means *running* the app,
        // which a cross-compiled artifact can't do — the project root here
        // doesn't exist, so a build attempt would throw.
        try await Build.validateAgentSurface(
            manifest: manifest,
            projectRoot: URL(fileURLWithPath: "/nonexistent-swift-pwa-project"),
            target: .android
        )
    }

    @Test("an app with no agent surface never triggers a catalog dump")
    func noSurfaceNeverBuilds() async throws {
        let manifest = try Self.minimalManifest()
        try await Build.validateAgentSurface(
            manifest: manifest,
            projectRoot: URL(fileURLWithPath: "/nonexistent-swift-pwa-project"),
            target: .host
        )
    }

    // MARK: - Drift between pwa.json and the compiled surface

    @Test("a matching declaration and binary is not drift")
    func noDriftWhenTheyAgree() {
        let section = Self.section(Self.expose("book.open", description: "Open a book.", readOnly: true))
        let compiled = [AgentTool(command: "book.open", description: "Open a book.", readOnly: true)]
        #expect(AgentPolicy.drift(declared: section, compiled: compiled).isEmpty)
    }

    @Test("declaring a surface but never installing the plugin fails")
    func declaredButNotWiredUp() {
        let problems = AgentPolicy.drift(declared: Self.section(Self.expose("book.open")), compiled: nil)
        #expect(problems.count == 1)
        #expect(problems[0].contains("installs no AgentPlugin"))
    }

    @Test("a tool compiled in but not declared fails — pwa.json must stay reviewable")
    func compiledButNotDeclared() {
        let problems = AgentPolicy.drift(
            declared: Self.section(Self.expose("book.open")),
            compiled: [
                AgentTool(command: "book.open", description: "Does a thing."),
                AgentTool(command: "book.delete", description: "Deletes.")
            ]
        )
        #expect(problems.contains { $0.contains("book.delete") && $0.contains("doesn't declare") })
    }

    @Test("a declared tool the app never passes to AgentPlugin fails")
    func declaredButNotCompiled() {
        let problems = AgentPolicy.drift(
            declared: Self.section(Self.expose("book.open"), Self.expose("book.delete")),
            compiled: [AgentTool(command: "book.open", description: "Does a thing.")]
        )
        #expect(problems.contains { $0.contains("book.delete") && $0.contains("never actually be offered") })
    }

    @Test("a description that differs between the two fails")
    func descriptionDrift() {
        let problems = AgentPolicy.drift(
            declared: Self.section(Self.expose("book.open", description: "Open a book.")),
            compiled: [AgentTool(command: "book.open", description: "Open anything at all.")]
        )
        // The description is what a user reads before allowing access, so the
        // reviewed copy describing something else is exactly the bad case.
        #expect(problems.contains { $0.contains("described differently") })
    }

    @Test("risk annotations that differ between the two fail")
    func annotationDrift() {
        let problems = AgentPolicy.drift(
            declared: Self.section(Self.expose("book.delete", destructive: true)),
            compiled: [AgentTool(command: "book.delete", description: "Does a thing.", readOnly: true)]
        )
        #expect(problems.contains { $0.contains("different risk annotations") })
    }

    @Test("neither side declaring anything is fine")
    func noSurfaceAtAll() {
        #expect(AgentPolicy.drift(declared: nil, compiled: nil).isEmpty)
        #expect(AgentPolicy.drift(declared: nil, compiled: []).isEmpty)
    }

    /// The reason, not just the refusal: both forbidden namespaces shared one
    /// error string for a release, so an app declaring `agent.enable` was told
    /// it would leak a credential and pointed at a fix for a problem it didn't
    /// have. Asserting only that the message mentions the namespace is what let
    /// that through, so this checks the explanation belongs to *this* refusal.
    @Test("the agent namespace can't be exposed — it would widen its own access")
    func agentNamespaceIsForbidden() {
        let resolution = AgentPolicy.resolve(Self.section(Self.expose("agent.enable")), against: [
            CommandDescriptor(name: "agent.enable", kind: .unary, args: .void, result: .void)
        ])
        #expect(resolution.tools.isEmpty)
        let error = try? #require(resolution.errors.first { $0.contains("agent.enable") })
        #expect(error?.contains("widen its own access") == true)
        #expect(error?.contains("credentials") == false, "this is the secret store's reason, not this one")
    }

    // MARK: - Manifest decoding

    @Test("the section round-trips through pwa.json's snake_case keys")
    func decodesFromManifest() throws {
        let json = """
        {
          "id": "com.example.books", "name": "Books", "version": "1.0.0",
          "web": { "directory": "web", "entry": "index.html" },
          "window": { "title": "Books", "width": 800, "height": 600, "resizable": true, "fullscreen": false },
          "agent": {
            "expose": [
              {
                "command": "book.delete", "description": "Delete a book.",
                "read_only": false, "destructive": true, "idempotent": true,
                "open_world": false, "tool_name": "remove_book"
              }
            ]
          }
        }
        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-agent-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let manifest = try PWAManifest.load(from: url)
        let entry = try #require(manifest.agent?.expose?.first)
        #expect(entry.command == "book.delete")
        #expect(entry.destructive == true)
        #expect(entry.readOnly == false)
        #expect(entry.idempotent == true)
        #expect(entry.openWorld == false)
        #expect(entry.toolName == "remove_book")

        let tool = try #require(AgentPolicy.resolve(manifest.agent, against: Self.catalog).tools.first)
        #expect(tool.name == "remove_book")
        #expect(tool.annotations?["idempotentHint"] == .bool(true))
        #expect(tool.annotations?["openWorldHint"] == .bool(false))
    }
}
