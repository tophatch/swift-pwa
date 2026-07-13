import Foundation
@testable import SwiftPWACore
@testable import SwiftPWARemoteAI
import Testing

// MARK: - Scripted transport (records requests, answers from a closure)

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

private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

/// The submit→poll→fetch dance, plus `/upload/image` and `/object_info`, so a
/// full `runWorkflow` / `inspectWorkflow` runs against no network.
private func choreography(
    imageBytes: Data = Data("IMG".utf8),
    uploadName: String = "uploaded.png",
    objectInfo: [String: Any] = [:]
) -> @Sendable (NetRequest) -> NetResponse {
    let objectInfoBody = json(objectInfo) // serialize now; Data is Sendable, [String:Any] isn't
    return { request in
        let path = request.url.path
        if path.hasSuffix("/upload/image") {
            return NetResponse(status: 200, body: json(["name": uploadName, "subfolder": "", "type": "input"]))
        } else if path.hasSuffix("/object_info") {
            return NetResponse(status: 200, body: objectInfoBody)
        } else if path.hasSuffix("/prompt") {
            return NetResponse(status: 200, body: json(["prompt_id": "p1"]))
        } else if path.contains("/history") {
            return NetResponse(status: 200, body: json([
                "p1": ["outputs": ["9": ["images": [["filename": "o.png", "subfolder": "", "type": "output"]]]]]
            ]))
        } else if path.hasSuffix("/view") {
            return NetResponse(status: 200, headers: ["Content-Type": "image/png"], body: imageBytes)
        }
        return NetResponse(status: 404)
    }
}

/// Pull the API-format graph back out of the POSTed `/prompt` body.
private func postedGraph(_ client: ScriptedClient) throws -> [String: Any] {
    let promptReq = try #require(client.requests.first { $0.url.path.hasSuffix("/prompt") })
    let bodyData = try #require(promptReq.body)
    let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    return try #require(body["prompt"] as? [String: Any])
}

private func inputs(_ graph: [String: Any], _ node: String) throws -> [String: Any] {
    try #require((graph[node] as? [String: Any])?["inputs"] as? [String: Any])
}

// MARK: - Fixtures

/// A graph whose nodes are titled so the title convention has something to bind:
/// KSampler titled `seed` (a named `seed` literal among many), two
/// `CLIPTextEncode`s titled `prompt` / `negative` (sole literal `text`), an
/// `EmptyLatentImage` titled `width`, a `LoadImage` titled `image`.
private let titledGraph = Data("""
{
  "3": { "class_type": "KSampler", "_meta": { "title": "seed" }, "inputs": {
      "seed": 0, "steps": 20, "cfg": 7.0, "model": ["4", 0],
      "positive": ["6", 0], "negative": ["7", 0], "latent_image": ["5", 0] } },
  "5": { "class_type": "EmptyLatentImage", "_meta": { "title": "width" },
      "inputs": { "width": 512, "height": 512, "batch_size": 1 } },
  "6": { "class_type": "CLIPTextEncode", "_meta": { "title": "prompt" },
      "inputs": { "text": "", "clip": ["4", 1] } },
  "7": { "class_type": "CLIPTextEncode", "_meta": { "title": "negative" },
      "inputs": { "text": "", "clip": ["4", 1] } },
  "10": { "class_type": "LoadImage", "_meta": { "title": "image" },
      "inputs": { "image": "default.png" } },
  "9": { "class_type": "SaveImage", "inputs": { "filename_prefix": "x", "images": ["8", 0] } }
}
""".utf8)

private let base = URL(string: "http://comfy.local:8188")!
private func provider() -> ComfyUIProvider {
    ComfyUIProvider(baseURL: base, pollInterval: .milliseconds(5), timeout: .milliseconds(500))
}

// MARK: - runWorkflow

@Suite("ComfyUI workflow runner")
struct WorkflowRunnerTests {
    @Test("title convention binds by node title (named key + sole-literal fallback)")
    func titleConvention() async throws {
        let client = ScriptedClient(choreography())
        let images = try await provider().runWorkflow(
            graph: titledGraph,
            inputs: [
                "prompt": .text("a red panda"),
                "negative": .text("blurry"),
                "seed": .seed(42),
                "width": .int(768)
            ],
            client: client
        )
        let graph = try postedGraph(client)
        #expect(try inputs(graph, "6")["text"] as? String == "a red panda") // sole literal `text`
        #expect(try inputs(graph, "7")["text"] as? String == "blurry")
        #expect(try inputs(graph, "3")["seed"] as? Int == 42) // named `seed` key among many
        #expect(try inputs(graph, "5")["width"] as? Int == 768) // named `width`, not height
        #expect(try inputs(graph, "5")["height"] as? Int == 512) // untouched
        #expect(images.first?.seed == 42)
    }

    @Test("explicit binding overrides the title convention and targets exact inputs")
    func explicitBinding() async throws {
        let client = ScriptedClient(choreography())
        _ = try await provider().runWorkflow(
            graph: titledGraph,
            inputs: ["cfg": .raw(.number(8)), "steps": .int(30)],
            bindings: [
                "cfg": .at(node: "3", input: "cfg"),
                "steps": .at(node: "3", input: "steps")
            ],
            client: client
        )
        let graph = try postedGraph(client)
        #expect(try inputs(graph, "3")["cfg"] as? Int == 8) // .raw integral → Int
        #expect(try inputs(graph, "3")["steps"] as? Int == 30)
    }

    @Test("one input fans out to every bound location")
    func fanOut() async throws {
        let client = ScriptedClient(choreography())
        _ = try await provider().runWorkflow(
            graph: titledGraph,
            inputs: ["size": .int(1024)],
            bindings: ["size": .at([("5", "width"), ("5", "height")])],
            client: client
        )
        let graph = try postedGraph(client)
        #expect(try inputs(graph, "5")["width"] as? Int == 1024)
        #expect(try inputs(graph, "5")["height"] as? Int == 1024)
    }

    @Test("a nil seed randomizes once and lands identically at every fan-out location")
    func seedRandomizeFanOut() async throws {
        let client = ScriptedClient(choreography())
        let images = try await provider().runWorkflow(
            graph: titledGraph,
            inputs: ["seed": .seed(nil)],
            bindings: ["seed": .at([("3", "seed"), ("5", "batch_size")])],
            client: client
        )
        let graph = try postedGraph(client)
        let a = try #require(try inputs(graph, "3")["seed"] as? Int)
        let b = try #require(try inputs(graph, "5")["batch_size"] as? Int)
        #expect(a == b) // same resolved seed everywhere
        #expect(images.first?.seed == a) // echoed on the result
    }

    @Test("an image input uploads via /upload/image and binds the returned filename")
    func imageUpload() async throws {
        let client = ScriptedClient(choreography(uploadName: "server-side.png"))
        _ = try await provider().runWorkflow(
            graph: titledGraph,
            inputs: ["image": .image(Data("PNGBYTES".utf8))],
            client: client // title convention → LoadImage node 10
        )
        let upload = try #require(client.requests.first { $0.url.path.hasSuffix("/upload/image") })
        #expect(upload.method == "POST")
        #expect(upload.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=") == true)
        let graph = try postedGraph(client)
        #expect(try inputs(graph, "10")["image"] as? String == "server-side.png")
    }

    @Test("an unbound / unknown input is ignored (no error, graph untouched there)")
    func unknownInputIgnored() async throws {
        let client = ScriptedClient(choreography())
        _ = try await provider().runWorkflow(
            graph: titledGraph,
            inputs: ["does_not_exist": .text("x")],
            client: client
        )
        let graph = try postedGraph(client)
        #expect(try inputs(graph, "6")["text"] as? String == "") // still the graph default
    }

    @Test("a non-object graph fails clearly")
    func badGraph() async {
        let client = ScriptedClient(choreography())
        await #expect(throws: AIError.self) {
            _ = try await provider().runWorkflow(graph: Data("[1,2,3]".utf8), inputs: [:], client: client)
        }
    }
}

// MARK: - inspectWorkflow

@Suite("ComfyUI workflow introspection")
struct WorkflowInspectTests {
    private let graph = Data("""
    {
      "3": { "class_type": "KSampler", "_meta": { "title": "sampler" }, "inputs": {
          "seed": 5, "steps": 20, "sampler_name": "euler", "model": ["4", 0] } },
      "10": { "class_type": "LoadImage", "_meta": { "title": "image" },
          "inputs": { "image": "a.png" } },
      "4": { "class_type": "CheckpointLoaderSimple",
          "inputs": { "ckpt_name": "m.safetensors" } }
    }
    """.utf8)

    private let objectInfo: [String: Any] = [
        "KSampler": ["input": ["required": [
            "seed": ["INT", ["min": 0, "max": 100, "step": 1]],
            "steps": ["INT", ["min": 1, "max": 50]],
            "sampler_name": [["euler", "dpm"], [String: Any]()]
        ]]],
        "LoadImage": ["input": ["required": [
            "image": [["a.png", "b.png"], ["image_upload": true]]
        ]]],
        "CheckpointLoaderSimple": ["input": ["required": [
            "ckpt_name": [["m.safetensors"], [String: Any]()]
        ]]]
    ]

    @Test("lists literal inputs enriched from /object_info; excludes connections")
    func inspects() async throws {
        let client = ScriptedClient(choreography(objectInfo: objectInfo))
        let all = try await provider().inspectWorkflow(graph: graph, client: client)

        // Connection input `model` (["4",0]) is excluded.
        #expect(!all.contains { $0.nodeID == "3" && $0.inputName == "model" })

        let seed = try #require(all.first { $0.nodeID == "3" && $0.inputName == "seed" })
        #expect(seed.type == "INT")
        #expect(seed.currentValue == .number(5))
        #expect(seed.min == 0 && seed.max == 100 && seed.step == 1)
        #expect(seed.title == "sampler")
        #expect(!seed.isImage)

        let sampler = try #require(all.first { $0.inputName == "sampler_name" })
        #expect(sampler.type == "COMBO")
        #expect(sampler.options == ["euler", "dpm"])

        let image = try #require(all.first { $0.nodeID == "10" && $0.inputName == "image" })
        #expect(image.isImage) // image_upload widget
        #expect(image.options == ["a.png", "b.png"])
        #expect(image.currentValue == .string("a.png"))

        // Numeric-natural node order: 3 before 10 before … (4 is titleless, last group).
        #expect(all.first?.nodeID == "3")
    }

    @Test("titledOnly excludes nodes without a _meta.title")
    func titledOnly() async throws {
        let client = ScriptedClient(choreography(objectInfo: objectInfo))
        let titled = try await provider().inspectWorkflow(graph: graph, client: client, titledOnly: true)
        #expect(!titled.contains { $0.nodeClass == "CheckpointLoaderSimple" }) // node 4 has no title
        #expect(titled.contains { $0.nodeID == "3" })
        #expect(titled.contains { $0.nodeID == "10" })
    }
}

// MARK: - ComfyWorkflowProvider (ai.* adapter)

@Suite("ComfyUI workflow → ai.* model adapter")
struct ComfyWorkflowProviderTests {
    private func makeBackend(
        _ client: ScriptedClient,
        fields: ComfyWorkflowProvider.FieldBindings
    ) -> RemoteImageBackend {
        RemoteImageBackend(
            provider: ComfyWorkflowProvider(
                baseURL: base,
                graph: titledGraph,
                fields: fields,
                model: AIModelInfo(
                    id: "comfy:workflow:demo", label: "Demo (ComfyUI)",
                    capabilities: [.imageGeneration, .imageEdit], availability: .ready, offlineCapable: false
                )
            ),
            client: client
        )
    }

    @Test("maps standard request fields onto the graph via runWorkflow")
    func mapsStandardFields() async throws {
        let client = ScriptedClient(choreography())
        let backend = makeBackend(client, fields: .init(
            prompt: .at(node: "6", input: "text"),
            seed: .at(node: "3", input: "seed")
        ))
        let result = try await backend.generateImage(
            AIGenerateImageRequest(prompt: "a fox", seed: 99)
        )
        let graph = try postedGraph(client)
        #expect(try inputs(graph, "6")["text"] as? String == "a fox")
        #expect(try inputs(graph, "3")["seed"] as? Int == 99)
        #expect(result.backend == "comfyui-workflow")
        #expect(result.images.first?.seed == 99)
    }

    @Test("a request image is uploaded and bound (the img2img / edit route)")
    func mapsImage() async throws {
        let client = ScriptedClient(choreography(uploadName: "edit-src.png"))
        let backend = makeBackend(client, fields: .init(
            prompt: .at(node: "6", input: "text"),
            image: .imageAt(node: "10", input: "image")
        ))
        _ = try await backend.generateImage(AIGenerateImageRequest(
            prompt: "make it snowy",
            image: .inline(Data("PNG".utf8).base64EncodedString())
        ))
        #expect(client.requests.contains { $0.url.path.hasSuffix("/upload/image") })
        let graph = try postedGraph(client)
        #expect(try inputs(graph, "10")["image"] as? String == "edit-src.png")
    }

    @Test("info advertises the model's capabilities to ai.info")
    func info() async {
        let client = ScriptedClient(choreography())
        let caps = await makeBackend(client, fields: .init()).info()
        #expect(caps.imageGeneration)
        #expect(caps.imageEditing)
        #expect(caps.models?.first?.id == "comfy:workflow:demo")
    }
}
