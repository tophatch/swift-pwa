import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

/// A workflow provider that records the config it was handed, so the plugin's
/// routing + `secretRef` resolution can be asserted without a real backend.
private final class CapturingProvider: AIWorkflowProvider, @unchecked Sendable {
    let providerID: String
    private let lock = NSLock()
    private var _config: AIWorkflowConfig?
    init(id: String = "fake") { providerID = id }
    var lastConfig: AIWorkflowConfig? {
        lock.withLock { _config }
    }

    func describeInputs(config: AIWorkflowConfig, client _: any NetworkClient) async throws -> AIInputSchema {
        lock.withLock { _config = config }
        return AIInputSchema(inputs: [AIInputField(key: "3/text", label: "prompt", type: .text)])
    }

    func runWorkflow(config: AIWorkflowConfig, client _: any NetworkClient)
        -> AsyncThrowingStream<AIRunEvent, any Error>
    {
        lock.withLock { _config = config }
        return AsyncThrowingStream { continuation in
            continuation.yield(.done)
            continuation.finish()
        }
    }
}

private struct DummyClient: NetworkClient {
    func send(_: NetRequest) async throws -> NetResponse { NetResponse(status: 200) }
    func download(_: NetDownloadRequest) -> AsyncThrowingStream<NetDownloadEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct FixedSecretStore: SecretStore {
    let value: String
    func get(_: String) async throws -> String? { value }
    func set(_: String, _: String) async throws {}
    func delete(_: String) async throws {}
}

@Suite("AIWorkflowPlugin")
@MainActor
struct AIWorkflowPluginTests {
    private func makeApp(_ provider: CapturingProvider, secret: String? = nil) -> MockAppContext {
        let app = MockAppContext()
        app.use(AIWorkflowPlugin(
            providers: [provider],
            client: DummyClient(),
            secrets: secret.map(FixedSecretStore.init)
        ))
        return app
    }

    private func dispatch(
        _ command: String,
        _ payload: [String: Any],
        on app: MockAppContext
    ) async -> InvocationResult {
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
        let inv = Invocation(id: 1, command: command, payload: data)
        return await app.registry.dispatch(CommandContext(invocation: inv, originWindow: nil, appContext: app))
    }

    @Test("ai.describeInputs routes to the named provider and returns its schema")
    func describeRoutes() async throws {
        let provider = CapturingProvider()
        let app = makeApp(provider)
        let result = await dispatch("ai.describeInputs", [
            "provider": "fake",
            "connection": ["baseURL": "http://box.local:8188"],
            "graph": "{}"
        ], on: app)
        guard case let .ok(data) = result else { Issue.record("expected .ok, got \(result)"); return }
        let schema = try JSONDecoder().decode(AIInputSchema.self, from: data)
        #expect(schema.inputs.first?.key == "3/text")
        #expect(provider.lastConfig?.connection.baseURL.absoluteString == "http://box.local:8188")
    }

    @Test("secretRef is resolved server-side and substituted into ${secret} headers")
    func secretSubstitution() async throws {
        let provider = CapturingProvider()
        let app = makeApp(provider, secret: "sk-live-123")
        _ = await dispatch("ai.describeInputs", [
            "provider": "fake",
            "connection": [
                "baseURL": "http://box.local:8188",
                "headers": ["Authorization": "Bearer ${secret}", "x-plain": "keep"],
                "secretRef": "plugin/apiKey"
            ],
            "graph": "{}"
        ], on: app)
        let headers = try #require(provider.lastConfig?.connection.headers)
        #expect(headers["Authorization"] == "Bearer sk-live-123") // substituted server-side
        #expect(headers["x-plain"] == "keep") // untouched
    }

    @Test("headers pass through unchanged when there's no secretRef")
    func headersPassthrough() async {
        let provider = CapturingProvider()
        let app = makeApp(provider)
        _ = await dispatch("ai.describeInputs", [
            "provider": "fake",
            "connection": ["baseURL": "http://box.local:8188", "headers": ["x-api-key": "abc"]],
            "graph": "{}"
        ], on: app)
        #expect(provider.lastConfig?.connection.headers["x-api-key"] == "abc")
    }

    @Test("an unknown provider id is an error naming the known providers")
    func unknownProvider() async {
        let app = makeApp(CapturingProvider(id: "comfyui"))
        let result = await dispatch("ai.describeInputs", [
            "provider": "nope",
            "connection": ["baseURL": "http://box.local:8188"],
            "graph": "{}"
        ], on: app)
        guard case .failure = result else { Issue.record("expected .failure for unknown provider"); return }
    }
}
