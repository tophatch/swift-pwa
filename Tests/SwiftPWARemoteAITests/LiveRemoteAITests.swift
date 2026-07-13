import Foundation
import SwiftPWACore
@testable import SwiftPWARemoteAI
import Testing

/// Opt-in live tests that hit real services — skipped unless the relevant env
/// var is set, so CI and offline runs don't touch the network:
///
/// - **ComfyUI:** set `SWIFT_PWA_LIVE_COMFY` to the instance origin
///   (e.g. `http://comfyui.local:8188`), optionally `SWIFT_PWA_LIVE_COMFY_CKPT`
///   for the checkpoint filename. For the workflow-runner tests, set
///   `SWIFT_PWA_LIVE_COMFY_WORKFLOW` to a path to an API-format graph JSON the
///   instance can run (a txt2img graph with a text prompt node), optionally
///   `SWIFT_PWA_LIVE_COMFY_PROMPT_NODE` (default `"108"`) and
///   `SWIFT_PWA_LIVE_COMFY_STEPS_NODE` for the node ids to bind.
/// - **Imagen:** set `GEMINI_API_KEY`.
///
/// Each writes the generated image into the system temp dir and asserts it's a
/// non-trivial image, exercising the whole `URLSessionNetworkClient` → provider
/// → decode path against the real API.
@Suite("Remote AI — live")
struct LiveRemoteAITests {
    private static let comfyURL = ProcessInfo.processInfo.environment["SWIFT_PWA_LIVE_COMFY"]
    private static let comfyWorkflow = ProcessInfo.processInfo.environment["SWIFT_PWA_LIVE_COMFY_WORKFLOW"]
    private static let geminiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
    private static let env = ProcessInfo.processInfo.environment

    @Test("ComfyUI: prompt → image", .enabled(if: comfyURL != nil))
    func comfyLive() async throws {
        let comfyURL = try #require(Self.comfyURL)
        let base = try #require(URL(string: comfyURL))
        // Auto-select whatever checkpoint the instance has — exercises the
        // /object_info discovery path, no hard-coded model name needed.
        let backend = RemoteImageBackend(
            provider: ComfyUIProvider(baseURL: base, autoSelectCheckpoint: true),
            client: URLSessionNetworkClient()
        )
        let result = try await backend.generateImage(AIGenerateImageRequest(
            prompt: "a red fox in a snowy forest, highly detailed",
            width: 1024, height: 1024, steps: 8, seed: 12345
        ))
        try assertImage(result, label: "comfy")
    }

    @Test(
        "ComfyUI: inspectWorkflow lists real overridable inputs",
        .enabled(if: comfyURL != nil && comfyWorkflow != nil)
    )
    func comfyInspectLive() async throws {
        let url = try #require(Self.comfyURL)
        let base = try #require(URL(string: url))
        let workflowPath = try #require(Self.comfyWorkflow)
        let graph = try Data(contentsOf: URL(fileURLWithPath: workflowPath))
        let provider = ComfyUIProvider(baseURL: base)
        let inputs = try await provider.inspectWorkflow(graph: graph, client: URLSessionNetworkClient())
        #expect(!inputs.isEmpty)
        // The real /object_info enriched at least one numeric input with a type
        // and a range — the parse this test exists to validate against a live
        // server (synthetic fixtures only approximate the shape).
        #expect(inputs.contains { $0.type == "INT" && $0.max != nil })
        #expect(inputs.contains { $0.type == "COMBO" && !($0.options ?? []).isEmpty })
        for input in inputs.prefix(40) {
            let range = input.min.map { "[\($0)…\(input.max ?? 0)]" } ?? ""
            print("  #\(input.nodeID) \(input.nodeClass).\(input.inputName): \(input.type ?? "?") \(range)"
                + (input.isImage ? " [image]" : ""))
        }
    }

    @Test(
        "ComfyUI: runWorkflow(imported graph) → image",
        .enabled(if: comfyURL != nil && comfyWorkflow != nil)
    )
    func comfyRunWorkflowLive() async throws {
        let url = try #require(Self.comfyURL)
        let base = try #require(URL(string: url))
        let workflowPath = try #require(Self.comfyWorkflow)
        let graph = try Data(contentsOf: URL(fileURLWithPath: workflowPath))
        let promptNode = Self.env["SWIFT_PWA_LIVE_COMFY_PROMPT_NODE"] ?? "108"
        let seedNode = Self.env["SWIFT_PWA_LIVE_COMFY_SEED_NODE"] ?? "106"
        var bindings: [String: WorkflowBinding] = [
            "prompt": .at(node: promptNode, input: "text"),
            "seed": .at(node: seedNode, input: "seed")
        ]
        var inputs: [String: WorkflowInputValue] = [
            "prompt": .text("a red fox in a snowy forest, highly detailed"),
            "seed": .seed(nil)
        ]
        // Keep the run quick if a steps node was named.
        if let stepsNode = Self.env["SWIFT_PWA_LIVE_COMFY_STEPS_NODE"] {
            bindings["steps"] = .at(node: stepsNode, input: "steps")
            inputs["steps"] = .int(8)
        }

        let provider = ComfyUIProvider(baseURL: base, timeout: .seconds(600))
        let images = try await provider.runWorkflow(
            graph: graph, inputs: inputs, bindings: bindings, client: URLSessionNetworkClient()
        )
        try assertImage(AIGenerateImageResult(images: images, backend: "comfyui"), label: "comfy-workflow")
    }

    @Test(
        "ComfyUI: runWorkflow with an uploaded image (img2img / upscale / edit)",
        .enabled(if: comfyURL != nil
            && env["SWIFT_PWA_LIVE_COMFY_IMAGE_WORKFLOW"] != nil
            && env["SWIFT_PWA_LIVE_COMFY_INPUT_IMAGE"] != nil)
    )
    func comfyImageWorkflowLive() async throws {
        let url = try #require(Self.comfyURL)
        let base = try #require(URL(string: url))
        let workflowPath = try #require(Self.env["SWIFT_PWA_LIVE_COMFY_IMAGE_WORKFLOW"])
        let inputPath = try #require(Self.env["SWIFT_PWA_LIVE_COMFY_INPUT_IMAGE"])
        let graph = try Data(contentsOf: URL(fileURLWithPath: workflowPath))
        let inputImage = try Data(contentsOf: URL(fileURLWithPath: inputPath))
        let imageNode = Self.env["SWIFT_PWA_LIVE_COMFY_IMAGE_NODE"] ?? "36"

        let provider = ComfyUIProvider(baseURL: base, timeout: .seconds(600))
        let images = try await provider.runWorkflow(
            graph: graph,
            inputs: ["image": .image(inputImage)],
            bindings: ["image": .imageAt(node: imageNode, input: "image")],
            client: URLSessionNetworkClient()
        )
        try assertImage(AIGenerateImageResult(images: images, backend: "comfyui"), label: "comfy-image")
    }

    @Test("Imagen: prompt → image", .enabled(if: geminiKey != nil))
    func imagenLive() async throws {
        let key = try #require(Self.geminiKey)
        let backend = RemoteImageBackend(
            provider: ImagenProvider(apiKey: { key }),
            client: URLSessionNetworkClient()
        )
        let result = try await backend.generateImage(AIGenerateImageRequest(
            prompt: "a corgi wearing sunglasses, studio photo",
            width: 1024, height: 1024, count: 1
        ))
        try assertImage(result, label: "imagen")
    }

    private func assertImage(_ result: AIGenerateImageResult, label: String) throws {
        let image = try #require(result.images.first)
        let bytes = try #require(image.dataBase64.flatMap { Data(base64Encoded: $0) })
        #expect(bytes.count > 1000) // a real image, not an error blob
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("remote-\(label).png")
        try bytes.write(to: out)
        print("[\(label)] \(result.backend): \(bytes.count) bytes, mime \(image.mimeType ?? "?") → \(out.path)")
    }
}
