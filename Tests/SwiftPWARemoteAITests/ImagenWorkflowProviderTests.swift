import Foundation
@testable import SwiftPWACore
@testable import SwiftPWARemoteAI
import Testing

/// A minimal scripted `NetworkClient` that captures requests and returns a canned
/// Imagen `:predict` response. (`openWebSocket` inherits the throwing default.)
private final class ScriptedClient: NetworkClient, @unchecked Sendable {
    private let handler: @Sendable (NetRequest) -> NetResponse
    private let lock = NSLock()
    private var _requests: [NetRequest] = []
    init(_ handler: @escaping @Sendable (NetRequest) -> NetResponse) { self.handler = handler }
    func send(_ request: NetRequest) async throws -> NetResponse {
        lock.withLock { _requests.append(request) }
        return handler(request)
    }

    func download(_: NetDownloadRequest) -> AsyncThrowingStream<NetDownloadEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    var requests: [NetRequest] {
        lock.withLock { _requests }
    }
}

/// A tiny 1×1 PNG so `.image` events carry real bytes.
private let onePixelPNGBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

private func predictResponse(count: Int) -> NetResponse {
    let predictions = (0 ..< count).map { _ in
        ["bytesBase64Encoded": onePixelPNGBase64, "mimeType": "image/png"]
    }
    return NetResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: ["predictions": predictions]))
}

private func collect(
    _ stream: AsyncThrowingStream<AIRunEvent, any Error>
) async throws -> [AIRunEvent] {
    var events: [AIRunEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

struct ImagenWorkflowProviderTests {
    @Test func describeInputsReturnsFixedSchema() async throws {
        let provider = ImagenProvider(apiKey: { "k" }) // defaults to two models
        let schema = try await provider.describeInputs(
            config: AIWorkflowConfig(connection: AIConnection(baseURL: #require(URL(string: "about:blank")))),
            client: ScriptedClient { _ in NetResponse(status: 404) }
        )
        #expect(!schema.degraded)
        let keys = schema.inputs.map(\.key)
        #expect(keys == ["prompt", "model", "aspectRatio", "count", "seed"])

        let aspect = try #require(schema.inputs.first { $0.key == "aspectRatio" })
        #expect(aspect.type == .enum)
        #expect(aspect.options == ImagenProvider.aspectRatios)

        let model = try #require(schema.inputs.first { $0.key == "model" })
        #expect(model.options?.count == 2)

        let count = try #require(schema.inputs.first { $0.key == "count" })
        #expect(count.type == .int)
        #expect(count.min == 1)
        #expect(count.max == 4)
    }

    @Test func describeInputsOmitsModelForSingleModel() async throws {
        let provider = ImagenProvider(
            apiKey: { "k" },
            models: [ImagenProvider.defaultModels[0]]
        )
        let schema = try await provider.describeInputs(
            config: AIWorkflowConfig(connection: AIConnection(baseURL: #require(URL(string: "about:blank")))),
            client: ScriptedClient { _ in NetResponse(status: 404) }
        )
        #expect(!schema.inputs.map(\.key).contains("model"))
    }

    @Test func runMapsInputsAndUsesConnectionKey() async throws {
        let client = ScriptedClient { _ in predictResponse(count: 2) }
        let provider = ImagenProvider(apiKey: { "injected" })
        let config = try AIWorkflowConfig(
            connection: AIConnection(
                baseURL: #require(URL(string: "https://example.test/v1beta")),
                headers: ["x-goog-api-key": "connection-key"]
            ),
            inputs: [
                "prompt": .string("a happy otter"),
                "aspectRatio": .string("16:9"),
                "count": .number(2)
            ]
        )
        let events = try await collect(provider.runWorkflow(config: config, client: client))

        // progress(running) → image → image → done
        #expect(events.first?.type == .progress)
        #expect(events.first?.stage == "running")
        #expect(events.count(where: { $0.type == .image }) == 2)
        #expect(events.last?.type == .done)

        // The request went to the connection's base + used its key header.
        let request = try #require(client.requests.first)
        #expect(request.url.absoluteString == "https://example.test/v1beta/models/imagen-4.0-generate-001:predict")
        #expect(request.headers["x-goog-api-key"] == "connection-key")

        // Body carried the prompt, aspect ratio, and a 2-sample count (no seed).
        let body = try #require(request.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let instances = try #require(json["instances"] as? [[String: Any]])
        #expect(instances.first?["prompt"] as? String == "a happy otter")
        let params = try #require(json["parameters"] as? [String: Any])
        #expect(params["aspectRatio"] as? String == "16:9")
        #expect(params["sampleCount"] as? Int == 2)
    }

    @Test func runFallsBackToInjectedKeyAndBaseURL() async throws {
        let client = ScriptedClient { _ in predictResponse(count: 1) }
        let provider = ImagenProvider(
            apiKey: { "injected-key" },
            baseURL: "https://injected.test/v1beta"
        )
        // A `${secret}` placeholder (unresolved) is treated as absent, and the
        // about:blank placeholder connection base is ignored → injected base used.
        let config = try AIWorkflowConfig(
            connection: AIConnection(
                baseURL: #require(URL(string: "about:blank")),
                headers: ["x-goog-api-key": "${secret}"]
            ),
            inputs: ["prompt": .string("a cat")]
        )
        _ = try await collect(provider.runWorkflow(config: config, client: client))

        let request = try #require(client.requests.first)
        #expect(request.url.absoluteString.hasPrefix("https://injected.test/v1beta/models/"))
        #expect(request.headers["x-goog-api-key"] == "injected-key")
    }

    @Test func runSeedForcesSingleSample() async throws {
        let client = ScriptedClient { _ in predictResponse(count: 1) }
        let provider = ImagenProvider(apiKey: { "k" })
        let config = try AIWorkflowConfig(
            connection: AIConnection(baseURL: #require(URL(string: "https://example.test/v1beta"))),
            inputs: ["prompt": .string("a cat"), "count": .number(4), "seed": .number(123)]
        )
        _ = try await collect(provider.runWorkflow(config: config, client: client))

        let body = try #require(client.requests.first?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let params = try #require(json["parameters"] as? [String: Any])
        // An explicit seed forces sampleCount = 1 and disables the watermark.
        #expect(params["sampleCount"] as? Int == 1)
        #expect(params["seed"] as? Int == 123)
        #expect(params["addWatermark"] as? Bool == false)
    }

    @Test func runWithoutPromptFails() async throws {
        let client = ScriptedClient { _ in predictResponse(count: 1) }
        let provider = ImagenProvider(apiKey: { "k" })
        let config = try AIWorkflowConfig(
            connection: AIConnection(baseURL: #require(URL(string: "https://example.test/v1beta"))),
            inputs: [:]
        )
        await #expect(throws: (any Error).self) {
            _ = try await collect(provider.runWorkflow(config: config, client: client))
        }
    }
}
