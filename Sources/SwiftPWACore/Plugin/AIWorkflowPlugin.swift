import Foundation

/// Optional plugin exposing the **runtime, JS-reachable** workflow surface on the
/// `ai.*` namespace — `ai.describeInputs` + `ai.run` — over one or more
/// ``AIWorkflowProvider``s. Separate from `AIPlugin` (which owns the fixed
/// `ai.generate*` model surface), sharing the `ai.*` namespace like `VisionPlugin`
/// does, and opt-in: the app installs it, supplies the providers + a
/// `NetworkClient`, and (optionally) a `SecretStore` for `secretRef` resolution.
///
/// The runtime door is gated on **capability present** — install this plugin +
/// hand it a net client — not on any pre-registered model, because the graph
/// *and* the connection travel in each call (there's no per-endpoint provider to
/// register).
///
/// JS surface (via the standard `invoke` / `subscribe`):
/// - `ai.describeInputs` → ``AIInputSchema`` (the overridable inputs for a
///   provider + connection [+ graph]).
/// - `ai.run` (subscribe) → ``AIRunEvent`` (`progress`… then `image`(s) then
///   `done`); `unsubscribe()` cancels (a provider issues its server-side
///   interrupt on stream teardown). A unary `invoke('ai.run', …)` also works and
///   resolves to the terminal images.
///
/// ```swift
/// ctx.use(AIWorkflowPlugin(
///     providers: [ComfyUIWorkflowProvider()],
///     client: URLSessionNetworkClient(),
///     secrets: KeychainSecretStore()))
/// ```
public struct AIWorkflowPlugin: Plugin {
    public static let pluginName = "ai-workflow"

    private let providers: [String: any AIWorkflowProvider]
    private let client: any NetworkClient
    private let secrets: (any SecretStore)?

    public init(
        providers: [any AIWorkflowProvider],
        client: any NetworkClient,
        secrets: (any SecretStore)? = nil
    ) {
        self.providers = Dictionary(providers.map { ($0.providerID, $0) }, uniquingKeysWith: { first, _ in first })
        self.client = client
        self.secrets = secrets
    }

    private struct DescribeArgs: Decodable {
        var provider: String
        var connection: AIConnection
        var graph: JSONValue?
        var titledOnly: Bool?
    }

    private struct RunArgs: Decodable {
        var provider: String
        var connection: AIConnection
        var graph: JSONValue?
        var inputs: [String: JSONValue]?
        var outputDirectory: String?
    }

    public func register(into registry: CommandRegistry, app _: any AppContext) {
        let providers = providers
        let client = client
        let secrets = secrets

        registry.register("ai.describeInputs", typed: {
            (args: DescribeArgs, _) async throws -> AIInputSchema in
            let provider = try Self.lookup(args.provider, in: providers)
            let config = try await Self.makeConfig(
                connection: args.connection, graph: args.graph,
                inputs: nil, titledOnly: args.titledOnly ?? false,
                outputDirectory: nil, secrets: secrets
            )
            return try await provider.describeInputs(config: config, client: client)
        })

        registry.registerStream("ai.run", typed: {
            (args: RunArgs, _) -> AsyncThrowingStream<AIRunEvent, any Error> in
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let provider = try Self.lookup(args.provider, in: providers)
                        let config = try await Self.makeConfig(
                            connection: args.connection, graph: args.graph,
                            inputs: args.inputs ?? [:], titledOnly: false,
                            outputDirectory: args.outputDirectory, secrets: secrets
                        )
                        for try await event in provider.runWorkflow(config: config, client: client) {
                            try Task.checkCancellation()
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                // Unsubscribe / window-close cancels the task; the provider's own
                // stream tears down (its `onTermination` issues the interrupt).
                continuation.onTermination = { _ in task.cancel() }
            }
        })
    }

    // MARK: - Helpers

    private static func lookup(
        _ id: String, in providers: [String: any AIWorkflowProvider]
    ) throws -> any AIWorkflowProvider {
        guard let provider = providers[id] else {
            throw AIError.generationFailed(
                "no workflow provider registered for '\(id)' (have: \(providers.keys.sorted().joined(separator: ", ")))"
            )
        }
        return provider
    }

    /// Resolve `secretRef` against the store (server-side) and substitute it into
    /// `${secret}` header placeholders, then assemble the config.
    private static func makeConfig(
        connection: AIConnection, graph: JSONValue?,
        inputs: [String: JSONValue]?, titledOnly: Bool,
        outputDirectory: String?, secrets: (any SecretStore)?
    ) async throws -> AIWorkflowConfig {
        var resolved = connection
        if let ref = connection.secretRef, let value = try await secrets?.get(ref) {
            resolved.headers = resolved.headers.mapValues { $0.replacingOccurrences(of: "${secret}", with: value) }
        }
        return try AIWorkflowConfig(
            connection: resolved,
            graph: graphData(graph),
            inputs: inputs ?? [:],
            titledOnly: titledOnly,
            outputDirectory: outputDirectory
        )
    }

    /// A graph arrives from JS either as a JSON object (decoded to `.object`) or
    /// a pre-serialized string; normalize to the API-format bytes providers want.
    private static func graphData(_ graph: JSONValue?) throws -> Data? {
        guard let graph else { return nil }
        if case let .string(string) = graph { return Data(string.utf8) }
        return try graph.encoded()
    }
}
