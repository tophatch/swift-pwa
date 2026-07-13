import Foundation
@testable import SwiftPWACore
@testable import SwiftPWARemoteAI
import Testing

/// Scripted client capturing the request and returning a canned response body.
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

private let onePixelPNGBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

private func j(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

private func collect(_ stream: AsyncThrowingStream<AIRunEvent, any Error>) async throws -> [AIRunEvent] {
    var events: [AIRunEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

// MARK: - Preset descriptors (the payloads a real app would ship / author)

private func imagenSpec() -> RESTImageAPISpec {
    RESTImageAPISpec(
        endpoint: "/models/${model}:predict",
        body: .object([
            "instances": .array([.object(["prompt": .string("${prompt}")])]),
            "parameters": .object([
                "sampleCount": .string("${count}"),
                "aspectRatio": .string("${aspectRatio}")
            ])
        ]),
        output: .init(
            kind: .base64,
            imagesPath: "predictions[*]",
            dataField: "bytesBase64Encoded",
            mimeField: "mimeType"
        ),
        errorPath: "error.message",
        fields: [
            AIInputField(key: "model", type: .enum, value: .string("imagen-4.0-generate-001")),
            AIInputField(key: "prompt", type: .text),
            AIInputField(key: "aspectRatio", type: .enum),
            AIInputField(key: "count", type: .int, value: .number(1))
        ]
    )
}

private func openAISpec() -> RESTImageAPISpec {
    RESTImageAPISpec(
        endpoint: "/v1/images/generations",
        body: .object([
            "model": .string("${model}"), "prompt": .string("${prompt}"), "n": .string("${count}")
        ]),
        output: .init(kind: .base64, imagesPath: "data[*]", dataField: "b64_json"),
        errorPath: "error.message",
        fields: [
            AIInputField(key: "model", type: .enum, value: .string("gpt-image-1")),
            AIInputField(key: "prompt", type: .text),
            AIInputField(key: "count", type: .int, value: .number(1))
        ]
    )
}

private func geminiSpec() -> RESTImageAPISpec {
    RESTImageAPISpec(
        endpoint: "/models/${model}:generateContent",
        body: .object([
            "contents": .array([.object(["parts": .array([.object(["text": .string("${prompt}")])])])])
        ]),
        output: .init(
            kind: .base64,
            imagesPath: "candidates[*].content.parts[*]",
            dataField: "inlineData.data",
            mimeField: "inlineData.mimeType"
        ),
        errorPath: "error.message",
        fields: [
            AIInputField(key: "model", type: .enum, value: .string("gemini-2.5-flash-image")),
            AIInputField(key: "prompt", type: .text)
        ]
    )
}

private func config(_ spec: RESTImageAPISpec, inputs: [String: JSONValue]) throws -> AIWorkflowConfig {
    try AIWorkflowConfig(
        connection: AIConnection(baseURL: #require(URL(string: "https://api.test/v1beta"))),
        graph: spec.encoded(),
        inputs: inputs
    )
}

private extension RESTImageAPISpec {
    func encoded() throws -> Data { try JSONEncoder().encode(self) }
}

struct RESTImageWorkflowProviderTests {
    // MARK: describeInputs

    @Test func describeInputsReturnsDescriptorFields() async throws {
        let provider = RESTImageWorkflowProvider()
        let schema = try await provider.describeInputs(
            config: config(imagenSpec(), inputs: [:]),
            client: ScriptedClient { _ in NetResponse(status: 200) }
        )
        #expect(!schema.degraded)
        #expect(schema.inputs.map(\.key) == ["model", "prompt", "aspectRatio", "count"])
    }

    // MARK: response-shape parsing

    @Test func imagenShapeExtractsImage() async throws {
        let client = ScriptedClient { _ in
            NetResponse(status: 200, body: j([
                "predictions": [["bytesBase64Encoded": onePixelPNGBase64, "mimeType": "image/png"]]
            ]))
        }
        let events = try await collect(RESTImageWorkflowProvider().runWorkflow(
            config: config(imagenSpec(), inputs: ["prompt": .string("a cat"), "count": .number(2)]),
            client: client
        ))
        #expect(events.first?.type == .progress)
        #expect(events.count(where: { $0.type == .image }) == 1)
        #expect(events.last?.type == .done)

        // endpoint templated with the model; body carried prompt + a numeric count.
        let request = try #require(client.requests.first)
        #expect(request.url.absoluteString == "https://api.test/v1beta/models/imagen-4.0-generate-001:predict")
        let rawBody = try #require(request.body)
        let bodyJSON = try #require(try JSONSerialization.jsonObject(with: rawBody) as? [String: Any])
        let instances = try #require(bodyJSON["instances"] as? [[String: Any]])
        #expect(instances.first?["prompt"] as? String == "a cat")
        let params = try #require(bodyJSON["parameters"] as? [String: Any])
        #expect(params["sampleCount"] as? Int == 2)
        // aspectRatio wasn't supplied → its placeholder key dropped out.
        #expect(params["aspectRatio"] == nil)
    }

    @Test func openAIShapeExtractsImage() async throws {
        let client = ScriptedClient { _ in
            NetResponse(status: 200, body: j(["data": [["b64_json": onePixelPNGBase64]]]))
        }
        let events = try await collect(RESTImageWorkflowProvider().runWorkflow(
            config: config(openAISpec(), inputs: ["prompt": .string("a dog")]),
            client: client
        ))
        #expect(events.count(where: { $0.type == .image }) == 1)
        let request = try #require(client.requests.first)
        #expect(request.url.absoluteString == "https://api.test/v1beta/v1/images/generations")
    }

    @Test func geminiShapeSkipsTextPartsAndExtractsImage() async throws {
        // Gemini interleaves a text part and an image part; only the image counts.
        let client = ScriptedClient { _ in
            NetResponse(status: 200, body: j([
                "candidates": [["content": ["parts": [
                    ["text": "Here's your image:"],
                    ["inlineData": ["mimeType": "image/png", "data": onePixelPNGBase64]]
                ]]]]
            ]))
        }
        let events = try await collect(RESTImageWorkflowProvider().runWorkflow(
            config: config(geminiSpec(), inputs: ["prompt": .string("a fox")]),
            client: client
        ))
        #expect(events.count(where: { $0.type == .image }) == 1)
        let image = try #require(events.first { $0.type == .image })
        #expect(image.image?.mimeType == "image/png")
    }

    @Test func urlOutputKindFetchesTheImage() async throws {
        let pngBytes = try #require(Data(base64Encoded: onePixelPNGBase64))
        let client = ScriptedClient { request in
            if request.url.absoluteString.contains("blob.test") {
                return NetResponse(status: 200, body: pngBytes) // the follow-up GET
            }
            return NetResponse(status: 200, body: j(["data": [["url": "https://blob.test/img.png"]]]))
        }
        var spec = openAISpec()
        spec.output = .init(kind: .url, imagesPath: "data[*]", dataField: "url")
        let events = try await collect(RESTImageWorkflowProvider().runWorkflow(
            config: config(spec, inputs: ["prompt": .string("x")]),
            client: client
        ))
        #expect(events.count(where: { $0.type == .image }) == 1)
        // Two requests: the generate POST + the image GET.
        #expect(client.requests.count == 2)
    }

    // MARK: binding + error paths

    @Test func seedIsRandomizedEchoedAndBound() async throws {
        var spec = openAISpec()
        spec.body = .object(["prompt": .string("${prompt}"), "seed": .string("${seed}")])
        spec.fields.append(AIInputField(key: "seed", type: .seed))
        let client = ScriptedClient { _ in
            NetResponse(status: 200, body: j(["data": [["b64_json": onePixelPNGBase64]]]))
        }
        let events = try await collect(RESTImageWorkflowProvider().runWorkflow(
            config: config(spec, inputs: ["prompt": .string("x"), "seed": .null]),
            client: client
        ))
        // A null seed → a concrete seed bound into the body AND echoed on the image.
        let rawBody = try #require(client.requests.first?.body)
        let body = try #require(try JSONSerialization.jsonObject(with: rawBody) as? [String: Any])
        let boundSeed = try #require(body["seed"] as? Int)
        let image = try #require(events.first { $0.type == .image })
        #expect(image.image?.seed == boundSeed)
    }

    @Test func errorPathSurfacesMessage() async throws {
        let client = ScriptedClient { _ in
            NetResponse(status: 400, body: j(["error": ["message": "quota exceeded"]]))
        }
        await #expect(throws: (any Error).self) {
            _ = try await collect(RESTImageWorkflowProvider().runWorkflow(
                config: config(imagenSpec(), inputs: ["prompt": .string("x")]),
                client: client
            ))
        }
    }

    @Test func descriptorRoundTripsThroughJSON() throws {
        // The descriptor must survive travelling as JSON in the call.
        let data = try imagenSpec().encoded()
        let decoded = try JSONDecoder().decode(RESTImageAPISpec.self, from: data)
        #expect(decoded == imagenSpec())
    }
}
