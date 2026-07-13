import Foundation
@testable import SwiftPWACore
@testable import SwiftPWARemoteAI
import Testing

private final class ScriptedWSClient: NetworkClient, @unchecked Sendable {
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

private func j(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

/// A tiny 1×1 PNG so `.image` events carry real bytes + parseable dimensions.
private let onePixelPNG = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

private let base = AIConnection(baseURL: URL(string: "http://comfy.local:8188")!)

private let graph = Data("""
{
  "3": { "class_type": "KSampler", "_meta": { "title": "KSampler" }, "inputs": {
      "seed": 0, "steps": 20, "model": ["4", 0], "positive": ["6", 0], "latent_image": ["5", 0] } },
  "6": { "class_type": "CLIPTextEncode", "_meta": { "title": "Positive" },
      "inputs": { "text": "", "clip": ["4", 1] } },
  "10": { "class_type": "LoadImage", "_meta": { "title": "Load Image" },
      "inputs": { "image": "default.png" } },
  "9": { "class_type": "SaveImage", "inputs": { "filename_prefix": "x", "images": ["8", 0] } }
}
""".utf8)

private func provider() -> ComfyUIWorkflowProvider {
    ComfyUIWorkflowProvider(pollInterval: .milliseconds(4), timeout: .milliseconds(500))
}

private func choreography() -> @Sendable (NetRequest) -> NetResponse {
    { request in
        let path = request.url.path
        if path.hasSuffix("/upload/image") {
            return NetResponse(status: 200, body: j(["name": "uploaded.png", "subfolder": "", "type": "input"]))
        } else if path.hasSuffix("/object_info") {
            return NetResponse(status: 200, body: j([
                "KSampler": ["input": ["required": [
                    "seed": ["INT", ["min": 0, "max": 100]],
                    "steps": ["INT", ["min": 1, "max": 50]]
                ]]],
                "CLIPTextEncode": ["input": ["required": ["text": ["STRING", [String: Any]()]]]],
                "LoadImage": ["input": ["required": ["image": [["a.png"], ["image_upload": true]]]]]
            ]))
        } else if path.hasSuffix("/prompt") {
            return NetResponse(status: 200, body: j(["prompt_id": "p1"]))
        } else if path.contains("/history") {
            return NetResponse(status: 200, body: j([
                "p1": ["outputs": ["9": ["images": [["filename": "o.png", "subfolder": "", "type": "output"]]]]]
            ]))
        } else if path.hasSuffix("/view") {
            return NetResponse(status: 200, headers: ["Content-Type": "image/png"], body: onePixelPNG)
        }
        return NetResponse(status: 404)
    }
}

@Suite("ComfyUIWorkflowProvider (runtime ai.run/ai.describeInputs)")
struct ComfyUIWorkflowProviderTests {
    @Test("describeInputs keys fields by node/input, enriches from /object_info")
    func describe() async throws {
        let client = ScriptedWSClient(choreography())
        let schema = try await provider().describeInputs(
            config: AIWorkflowConfig(connection: base, graph: graph), client: client
        )
        #expect(!schema.degraded)
        let seed = try #require(schema.inputs.first { $0.key == "3/seed" })
        #expect(seed.type == .seed) // seed input → .seed
        #expect(seed.max == 100)
        let text = try #require(schema.inputs.first { $0.key == "6/text" })
        #expect(text.type == .text)
        #expect(text.label == "Positive") // node title becomes the label
        let image = try #require(schema.inputs.first { $0.key == "10/image" })
        #expect(image.isImage && image.type == .image)
        // Connection inputs (model / positive / latent_image) are excluded.
        #expect(!schema.inputs.contains { $0.key == "3/model" })
    }

    @Test("describeInputs degrades to a graph-only schema when /object_info is unreachable")
    func describeDegraded() async throws {
        let client = ScriptedWSClient { req in
            req.url.path.hasSuffix("/object_info") ? NetResponse(status: 500) : NetResponse(status: 404)
        }
        let schema = try await provider().describeInputs(
            config: AIWorkflowConfig(connection: base, graph: graph), client: client
        )
        #expect(schema.degraded)
        #expect(schema.inputs.contains { $0.key == "6/text" }) // still lists literals
        #expect(schema.inputs.allSatisfy { $0.options == nil }) // no combo options without the catalog
    }

    @Test("runWorkflow binds inputs by key, uploads images, streams progress→image→done, echoes seed")
    func run() async throws {
        let client = ScriptedWSClient(choreography())
        let config = AIWorkflowConfig(
            connection: base, graph: graph,
            inputs: [
                "6/text": .string("a red panda"),
                "3/seed": .number(77),
                "10/image": .object(["dataBase64": .string(Data("PNG".utf8).base64EncodedString())])
            ]
        )
        var events: [AIRunEvent] = []
        for try await event in provider().runWorkflow(config: config, client: client) {
            events.append(event)
        }
        // Event shape: at least one progress, one image, a terminal done.
        #expect(events.contains { $0.type == .progress && $0.stage == "queued" })
        #expect(events.last?.type == .done)
        let imageEvent = try #require(events.first { $0.type == .image })
        #expect(imageEvent.image?.seed == 77) // resolved seed echoed
        #expect(imageEvent.width == 1 && imageEvent.height == 1) // PNG dims parsed

        // The posted graph carries the bound values + the uploaded filename.
        let promptReq = try #require(client.requests.first { $0.url.path.hasSuffix("/prompt") })
        let promptBody = try #require(promptReq.body)
        let body = try #require(try JSONSerialization.jsonObject(with: promptBody) as? [String: Any])
        let posted = try #require(body["prompt"] as? [String: Any])
        func inputs(_ node: String) -> [String: Any]? { (posted[node] as? [String: Any])?["inputs"] as? [String: Any] }
        #expect(inputs("6")?["text"] as? String == "a red panda")
        #expect(inputs("3")?["seed"] as? Int == 77)
        #expect(inputs("10")?["image"] as? String == "uploaded.png") // uploaded, filename bound
        #expect(client.requests.contains { $0.url.path.hasSuffix("/upload/image") })
    }

    @Test("a nil seed randomizes and is echoed on the image")
    func seedRandomize() async throws {
        let client = ScriptedWSClient(choreography())
        let config = AIWorkflowConfig(connection: base, graph: graph, inputs: ["3/seed": .null])
        var seeds: [Int?] = []
        for try await event in provider().runWorkflow(config: config, client: client) where event.type == .image {
            seeds.append(event.image?.seed)
        }
        let firstSeed: Int? = seeds.first ?? nil
        let seed = try #require(firstSeed)
        let promptReq = try #require(client.requests.first { $0.url.path.hasSuffix("/prompt") })
        let promptBody = try #require(promptReq.body)
        let posted = try #require(try JSONSerialization.jsonObject(with: promptBody) as? [String: Any])
        let graphOut = try #require(posted["prompt"] as? [String: Any])
        let boundSeed = ((graphOut["3"] as? [String: Any])?["inputs"] as? [String: Any])?["seed"] as? Int
        #expect(boundSeed == seed) // the echoed seed is exactly what was bound
    }
}
