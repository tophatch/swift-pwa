import Foundation
@testable import SwiftPWACore
@testable import SwiftPWARemoteAI
import Testing

// MARK: - Scripted transport

/// A `NetworkClient` that answers each `send` from a caller-supplied closure and
/// records every request — enough to drive both providers end-to-end (including
/// ComfyUI's multi-step choreography) without a network.
private final class ScriptedNetworkClient: NetworkClient, @unchecked Sendable {
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

private func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

// MARK: - Imagen

@Suite("ImagenProvider")
struct ImagenProviderTests {
    private func backend(_ client: ScriptedNetworkClient, key: String? = "test-key") -> RemoteImageBackend {
        RemoteImageBackend(provider: ImagenProvider(apiKey: { key }), client: client)
    }

    @Test("builds the :predict request and parses predictions")
    func predictRoundTrip() async throws {
        let pngBytes = Data("PNGDATA".utf8)
        let client = ScriptedNetworkClient { _ in
            NetResponse(status: 200, headers: [:], body: json([
                "predictions": [["bytesBase64Encoded": pngBytes.base64EncodedString(), "mimeType": "image/png"]]
            ]))
        }
        let result = try await backend(client).generateImage(AIGenerateImageRequest(prompt: "a cat", count: 1))

        let sent = try #require(client.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.url.absoluteString.hasSuffix("/models/imagen-4.0-generate-001:predict"))
        #expect(sent.headers["x-goog-api-key"] == "test-key")
        let body = try #require(sent.body)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let instances = try #require(decoded["instances"] as? [[String: Any]])
        #expect(instances.first?["prompt"] as? String == "a cat")

        #expect(result.backend == "google-imagen")
        #expect(result.images.count == 1)
        #expect(Data(base64Encoded: result.images[0].dataBase64 ?? "") == pngBytes)
        #expect(result.images[0].mimeType == "image/png")
    }

    @Test("a missing API key fails before any request")
    func missingKey() async {
        let client = ScriptedNetworkClient { _ in NetResponse(status: 200) }
        await #expect(throws: AIError.self) {
            _ = try await backend(client, key: nil).generateImage(AIGenerateImageRequest(prompt: "x"))
        }
        #expect(client.requests.isEmpty)
    }

    @Test("a non-2xx surfaces the API error message")
    func apiError() async throws {
        let client = ScriptedNetworkClient { _ in
            NetResponse(status: 400, headers: [:], body: json(["error": ["code": 400, "message": "bad prompt"]]))
        }
        await #expect(throws: AIError.self) {
            _ = try await backend(client).generateImage(AIGenerateImageRequest(prompt: "x"))
        }
    }

    @Test("request.model routes to the named Imagen variant")
    func modelRouting() async throws {
        let client = ScriptedNetworkClient { _ in
            NetResponse(status: 200, headers: [:], body: json([
                "predictions": [["bytesBase64Encoded": Data("x".utf8).base64EncodedString()]]
            ]))
        }
        _ = try await backend(client).generateImage(
            AIGenerateImageRequest(prompt: "x", model: "imagen-3.0-generate-002")
        )
        #expect(client.requests.first?.url.absoluteString.hasSuffix("/models/imagen-3.0-generate-002:predict") == true)
    }

    @Test("an explicit seed disables the watermark and forces a single sample")
    func explicitSeed() async throws {
        let client = ScriptedNetworkClient { _ in
            NetResponse(status: 200, headers: [:], body: json([
                "predictions": [["bytesBase64Encoded": Data("x".utf8).base64EncodedString()]]
            ]))
        }
        _ = try await backend(client).generateImage(AIGenerateImageRequest(prompt: "x", seed: 42, count: 4))
        let body = try #require(client.requests.first?.body)
        let params = try #require(try (JSONSerialization.jsonObject(with: body) as? [String: Any])?["parameters"]
            as? [String: Any])
        #expect(params["seed"] as? Int == 42)
        #expect(params["addWatermark"] as? Bool == false)
        #expect(params["sampleCount"] as? Int == 1) // seed forces a single sample
    }

    @Test("outputDirectory writes a file and returns its path")
    func outputToDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("imagen-\(UInt64.random(in: 0 ..< .max))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pngBytes = Data("PNGDATA".utf8)
        let client = ScriptedNetworkClient { _ in
            NetResponse(status: 200, headers: [:], body: json([
                "predictions": [["bytesBase64Encoded": pngBytes.base64EncodedString(), "mimeType": "image/png"]]
            ]))
        }
        let result = try await backend(client).generateImage(
            AIGenerateImageRequest(prompt: "x", outputDirectory: dir.path)
        )
        let path = try #require(result.images.first?.path)
        #expect(result.images.first?.dataBase64 == nil)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == pngBytes)
    }

    @Test("info advertises the Imagen catalog")
    func info() async {
        let caps = await backend(ScriptedNetworkClient { _ in NetResponse(status: 200) }).info()
        #expect(caps.backend == "google-imagen")
        #expect(caps.available)
        #expect(caps.imageGeneration)
        #expect(caps.models?.contains { $0.id == "imagen-4.0-generate-001" } == true)
    }

    @Test("ensureModel completes immediately for a ready remote model (no download)")
    func ensureModelNoOp() async throws {
        let backend = backend(ScriptedNetworkClient { _ in NetResponse(status: 200) })
        var events: [AIDownloadEvent] = []
        for try await event in backend.ensureModel(AIEnsureModelRequest(model: "imagen-4.0-generate-001")) {
            events.append(event)
        }
        #expect(events.contains { $0.type == "done" }) // done, not a thrown/unsupported error
    }
}

// MARK: - ComfyUI

@Suite("ComfyUIProvider")
struct ComfyUIProviderTests {
    private let base = URL(string: "http://comfy.local:8188")!

    private func backend(_ client: ScriptedNetworkClient) -> RemoteImageBackend {
        RemoteImageBackend(
            provider: ComfyUIProvider(baseURL: base, pollInterval: .milliseconds(5), timeout: .milliseconds(300)),
            client: client
        )
    }

    /// Route by path: POST /prompt → prompt_id; GET /history/* → outputs; GET
    /// /view → image bytes.
    private func choreography(imageBytes: Data) -> @Sendable (NetRequest) -> NetResponse {
        { request in
            let path = request.url.path
            if path.hasSuffix("/prompt") {
                return NetResponse(status: 200, headers: [:], body: json(["prompt_id": "abc123"]))
            } else if path.contains("/history") {
                return NetResponse(status: 200, headers: [:], body: json([
                    "abc123": ["outputs": ["9": ["images": [
                        ["filename": "out.png", "subfolder": "", "type": "output"]
                    ]]]]
                ]))
            } else if path.hasSuffix("/view") {
                return NetResponse(status: 200, headers: ["Content-Type": "image/png"], body: imageBytes)
            }
            return NetResponse(status: 404)
        }
    }

    @Test("submit → poll → fetch, patching the graph and returning the image")
    func fullChoreography() async throws {
        let imageBytes = Data("COMFYIMG".utf8)
        let client = ScriptedNetworkClient(choreography(imageBytes: imageBytes))
        let result = try await backend(client).generateImage(
            AIGenerateImageRequest(prompt: "a fox", steps: 12, seed: 7)
        )

        // The POSTed graph was patched with prompt + seed.
        let promptReq = try #require(client.requests.first { $0.url.path.hasSuffix("/prompt") })
        let promptBody = try #require(promptReq.body)
        let body = try #require(try JSONSerialization.jsonObject(with: promptBody) as? [String: Any])
        let graph = try #require(body["prompt"] as? [String: Any])
        let positive = try #require((graph["6"] as? [String: Any])?["inputs"] as? [String: Any])
        #expect(positive["text"] as? String == "a fox")
        let sampler = try #require((graph["3"] as? [String: Any])?["inputs"] as? [String: Any])
        #expect(sampler["seed"] as? Int == 7)
        #expect(sampler["steps"] as? Int == 12)
        #expect(body["client_id"] != nil)

        // The fetched image comes back.
        #expect(result.backend == "comfyui")
        #expect(Data(base64Encoded: result.images.first?.dataBase64 ?? "") == imageBytes)
        #expect(result.images.first?.seed == 7)
    }

    @Test("autoSelectCheckpoint discovers the instance's checkpoint and patches the graph")
    func autoSelectCheckpoint() async throws {
        let client = ScriptedNetworkClient { request in
            let path = request.url.path
            if path.contains("/object_info") {
                return NetResponse(status: 200, headers: [:], body: json([
                    "CheckpointLoaderSimple": ["input": ["required": [
                        "ckpt_name": [["modelA.safetensors", "modelB.safetensors"], [String: Any]()]
                    ]]]
                ]))
            } else if path.hasSuffix("/prompt") {
                return NetResponse(status: 200, headers: [:], body: json(["prompt_id": "p1"]))
            } else if path.contains("/history") {
                return NetResponse(status: 200, headers: [:], body: json([
                    "p1": ["outputs": ["9": ["images": [["filename": "o.png", "subfolder": "", "type": "output"]]]]]
                ]))
            } else if path.hasSuffix("/view") {
                return NetResponse(status: 200, headers: ["Content-Type": "image/png"], body: Data("IMG".utf8))
            }
            return NetResponse(status: 404)
        }
        let backend = RemoteImageBackend(
            provider: ComfyUIProvider(
                baseURL: base, autoSelectCheckpoint: true,
                pollInterval: .milliseconds(5), timeout: .milliseconds(300)
            ),
            client: client
        )
        _ = try await backend.generateImage(AIGenerateImageRequest(prompt: "x"))

        let promptReq = try #require(client.requests.first { $0.url.path.hasSuffix("/prompt") })
        let promptBody = try #require(promptReq.body)
        let body = try #require(try JSONSerialization.jsonObject(with: promptBody) as? [String: Any])
        let graph = try #require(body["prompt"] as? [String: Any])
        let loader = try #require((graph["4"] as? [String: Any])?["inputs"] as? [String: Any])
        #expect(loader["ckpt_name"] as? String == "modelA.safetensors") // first discovered
    }

    @Test("discoverModels lists one comfy:<ckpt> model per installed checkpoint")
    func discoverModels() async throws {
        let client = ScriptedNetworkClient { _ in
            NetResponse(status: 200, headers: [:], body: json([
                "CheckpointLoaderSimple": ["input": ["required": [
                    "ckpt_name": [["modelA.safetensors", "modelB.safetensors"], [String: Any]()]
                ]]]
            ]))
        }
        let provider = ComfyUIProvider(baseURL: base)
        let models = try await provider.discoverModels(client: client)
        #expect(models.map(\.id) == ["comfy:modelA.safetensors", "comfy:modelB.safetensors"])
        #expect(models.allSatisfy { $0.availability == .ready && !$0.offlineCapable })
        #expect(models[0].capabilities.contains(.imageGeneration))
    }

    @Test("a comfy:<ckpt> request.model patches that exact checkpoint")
    func checkpointRouting() async throws {
        let client = ScriptedNetworkClient(choreography(imageBytes: Data("IMG".utf8)))
        let backend = RemoteImageBackend(
            provider: ComfyUIProvider(baseURL: base, pollInterval: .milliseconds(5), timeout: .milliseconds(300)),
            client: client
        )
        _ = try await backend.generateImage(
            AIGenerateImageRequest(prompt: "x", model: "comfy:modelB.safetensors")
        )
        let promptReq = try #require(client.requests.first { $0.url.path.hasSuffix("/prompt") })
        let promptBody = try #require(promptReq.body)
        let body = try #require(try JSONSerialization.jsonObject(with: promptBody) as? [String: Any])
        let graph = try #require(body["prompt"] as? [String: Any])
        let loader = try #require((graph["4"] as? [String: Any])?["inputs"] as? [String: Any])
        #expect(loader["ckpt_name"] as? String == "modelB.safetensors")
    }

    @Test("a /prompt validation error fails the generate")
    func promptError() async {
        let client = ScriptedNetworkClient { request in
            request.url.path.hasSuffix("/prompt")
                ? NetResponse(status: 400, headers: [:], body: Data(#"{"error":"bad node"}"#.utf8))
                : NetResponse(status: 200)
        }
        await #expect(throws: AIError.self) {
            _ = try await backend(client).generateImage(AIGenerateImageRequest(prompt: "x"))
        }
    }

    @Test("history that never yields outputs times out")
    func timeout() async {
        let client = ScriptedNetworkClient { request in
            request.url.path.hasSuffix("/prompt")
                ? NetResponse(status: 200, headers: [:], body: json(["prompt_id": "abc123"]))
                : NetResponse(status: 200, headers: [:], body: json(["abc123": [String: Any]()])) // no outputs
        }
        await #expect(throws: AIError.self) {
            _ = try await backend(client).generateImage(AIGenerateImageRequest(prompt: "x"))
        }
    }
}
