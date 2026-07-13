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

struct RESTImageProviderTests {
    // MARK: describeInputs

    @Test func describeInputsReturnsDescriptorFields() async throws {
        let provider = RESTImageProvider()
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
        let events = try await collect(RESTImageProvider().runWorkflow(
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
        let events = try await collect(RESTImageProvider().runWorkflow(
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
        let events = try await collect(RESTImageProvider().runWorkflow(
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
        let events = try await collect(RESTImageProvider().runWorkflow(
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
        let events = try await collect(RESTImageProvider().runWorkflow(
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
            _ = try await collect(RESTImageProvider().runWorkflow(
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

    // MARK: multipart (edits)

    @Test func multipartEditBuildsFileAndTextParts() async throws {
        let client = ScriptedClient { _ in
            NetResponse(status: 200, body: j(["data": [["b64_json": onePixelPNGBase64]]]))
        }
        let config = try AIWorkflowConfig(
            connection: AIConnection(baseURL: #require(URL(string: "https://api.openai.test/v1"))),
            graph: RESTImageAPISpec.openAIEdit().encoded(),
            inputs: [
                "prompt": .string("make it snowy"),
                "image": .object(["dataBase64": .string(onePixelPNGBase64)])
                // no mask → that file part is omitted
            ]
        )
        let events = try await collect(RESTImageProvider().runWorkflow(config: config, client: client))
        #expect(events.count(where: { $0.type == .image }) == 1)

        let request = try #require(client.requests.first)
        #expect(request.url.absoluteString == "https://api.openai.test/v1/images/edits")
        let contentType = try #require(request.headers["Content-Type"])
        #expect(contentType.hasPrefix("multipart/form-data; boundary=----swiftpwa-"))
        // RFC 2046: boundary ≤ 70 chars.
        let boundary = String(contentType.split(separator: "=", maxSplits: 1)[1])
        #expect(boundary.count <= 70)
        let bodyText = try String(decoding: #require(request.body), as: UTF8.self)
        #expect(bodyText.contains("name=\"image\"; filename=\"image.png\""))
        #expect(bodyText.contains("name=\"prompt\""))
        #expect(bodyText.contains("make it snowy"))
        #expect(!bodyText.contains("name=\"mask\"")) // omitted (no mask supplied)
    }

    // MARK: async submit → poll (job APIs)

    @Test func asyncPollSubmitsThenPollsUntilSucceeded() async throws {
        let pngBytes = try #require(Data(base64Encoded: onePixelPNGBase64))
        let pollCount = Counter()
        let client = ScriptedClient { request in
            let path = request.url.path
            if path.contains("image-synthesis") { // submit
                return NetResponse(status: 200, body: j(["output": ["task_id": "task-1", "task_status": "PENDING"]]))
            }
            if path.contains("/tasks/task-1") { // poll — PENDING once, then SUCCEEDED
                let n = pollCount.next()
                if n < 2 {
                    return NetResponse(status: 200, body: j(["output": ["task_status": "RUNNING"]]))
                }
                return NetResponse(status: 200, body: j([
                    "output": ["task_status": "SUCCEEDED", "results": [["url": "https://oss.test/out.png"]]]
                ]))
            }
            if request.url.absoluteString.contains("oss.test") { return NetResponse(status: 200, body: pngBytes) }
            return NetResponse(status: 404)
        }
        // A fast poll interval so the test doesn't dawdle.
        var spec = RESTImageAPISpec.qwen()
        spec.flow.pollIntervalMs = 5
        let config = try AIWorkflowConfig(
            connection: AIConnection(baseURL: #require(URL(string: "https://dashscope.test/api/v1"))),
            graph: spec.encoded(),
            inputs: ["prompt": .string("a red fox")]
        )
        let events = try await collect(RESTImageProvider().runWorkflow(config: config, client: client))
        // The submit carried X-DashScope-Async, and the status changes surfaced as progress.
        let submit = try #require(client.requests.first)
        #expect(submit.headers["X-DashScope-Async"] == "enable")
        let stages = events.filter { $0.type == .progress }.compactMap(\.stage)
        #expect(stages.contains("running"))
        #expect(stages.contains("succeeded"))
        #expect(events.count(where: { $0.type == .image }) == 1)
        #expect(events.last?.type == .done)
    }

    @Test func asyncPollFailsFastOnFailureStatus() async throws {
        let client = ScriptedClient { request in
            if request.url.path.contains("image-synthesis") {
                return NetResponse(status: 200, body: j(["output": ["task_id": "t", "task_status": "PENDING"]]))
            }
            return NetResponse(status: 200, body: j(["output": ["task_status": "FAILED"]]))
        }
        var spec = RESTImageAPISpec.qwen()
        spec.flow.pollIntervalMs = 5
        let config = try AIWorkflowConfig(
            connection: AIConnection(baseURL: #require(URL(string: "https://dashscope.test/api/v1"))),
            graph: spec.encoded(),
            inputs: ["prompt": .string("x")]
        )
        await #expect(throws: (any Error).self) {
            _ = try await collect(RESTImageProvider().runWorkflow(config: config, client: client))
        }
    }
}

/// A tiny thread-safe counter for the scripted poll sequence.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}
