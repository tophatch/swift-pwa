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
    private static let openAIKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    private static let dashscopeKey = ProcessInfo.processInfo.environment["DASHSCOPE_API_KEY"]
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

    // MARK: - Runtime workflow provider (ai.run / ai.describeInputs)

    @Test(
        "ComfyUIWorkflowProvider: describeInputs against a live box",
        .enabled(if: comfyURL != nil && comfyWorkflow != nil)
    )
    func runtimeDescribeLive() async throws {
        let url = try #require(Self.comfyURL)
        let base = try #require(URL(string: url))
        let graph = try Data(contentsOf: URL(fileURLWithPath: #require(Self.comfyWorkflow)))
        let schema = try await ComfyUIWorkflowProvider().describeInputs(
            config: AIWorkflowConfig(connection: AIConnection(baseURL: base), graph: graph),
            client: URLSessionNetworkClient()
        )
        #expect(!schema.degraded)
        #expect(!schema.inputs.isEmpty)
        #expect(schema.inputs.allSatisfy { $0.key.contains("/") }) // "<node>/<input>"
        #expect(schema.inputs.contains { $0.type == .int && $0.max != nil })
        for field in schema.inputs.prefix(30) {
            print("  \(field.key)  [\(field.type.rawValue)] \(field.label ?? "")"
                + (field.options.map { " opts=\($0.count)" } ?? ""))
        }
    }

    @Test(
        "ComfyUIWorkflowProvider: ai.run streams progress → image → done, echoes seed",
        .enabled(if: comfyURL != nil && comfyWorkflow != nil)
    )
    func runtimeRunLive() async throws {
        let url = try #require(Self.comfyURL)
        let base = try #require(URL(string: url))
        let graph = try Data(contentsOf: URL(fileURLWithPath: #require(Self.comfyWorkflow)))
        let promptNode = Self.env["SWIFT_PWA_LIVE_COMFY_PROMPT_NODE"] ?? "108"
        let seedNode = Self.env["SWIFT_PWA_LIVE_COMFY_SEED_NODE"] ?? "106"
        var inputs: [String: JSONValue] = [
            "\(promptNode)/text": .string("a red fox in a snowy forest, highly detailed"),
            "\(seedNode)/seed": .null
        ]
        if let stepsNode = Self.env["SWIFT_PWA_LIVE_COMFY_STEPS_NODE"] {
            inputs["\(stepsNode)/steps"] = .number(8)
        }
        var stages: [String] = []
        var fineProgress = 0 // per-step /ws frames carry value/max
        var lastMax: Double?
        var imageEvent: AIRunEvent?
        var sawDone = false
        for try await event in ComfyUIWorkflowProvider(timeout: .seconds(600)).runWorkflow(
            config: AIWorkflowConfig(connection: AIConnection(baseURL: base), graph: graph, inputs: inputs),
            client: URLSessionNetworkClient()
        ) {
            switch event.type {
            case .progress:
                stages.append(event.stage ?? "?")
                if event.value != nil { fineProgress += 1; lastMax = event.max }
            case .image: imageEvent = event
            case .done: sawDone = true
            }
        }
        #expect(stages.contains("queued"))
        #expect(sawDone)
        #expect(fineProgress > 0) // /ws per-step progress reached us (1b)
        let image = try #require(imageEvent?.image)
        let seed = try #require(imageEvent?.image?.seed)
        let bytes = try #require(image.dataBase64.flatMap { Data(base64Encoded: $0) })
        #expect(bytes.count > 1000)
        // Persist so the runtime-path output can be eyeballed (the older
        // provider tests write remote-comfy*.png; this writes remote-runtime-run.png).
        try assertImage(AIGenerateImageResult(images: [image], backend: "comfyui-runtime"), label: "runtime-run")
        print("[runtime.run] seed=\(seed) dims=\(imageEvent?.width ?? 0)x\(imageEvent?.height ?? 0) "
            +
            "fineProgress=\(fineProgress)/\(lastMax.map { Int($0) } ?? 0) stages=\(stages.count) bytes=\(bytes.count)")
    }

    @Test(
        "ComfyUIWorkflowProvider: cancel (stream teardown) interrupts the job",
        .enabled(if: comfyURL != nil && comfyWorkflow != nil)
    )
    func runtimeCancelLive() async throws {
        let url = try #require(Self.comfyURL)
        let base = try #require(URL(string: url))
        let graph = try Data(contentsOf: URL(fileURLWithPath: #require(Self.comfyWorkflow)))
        let promptNode = Self.env["SWIFT_PWA_LIVE_COMFY_PROMPT_NODE"] ?? "108"
        // No low steps here — we want a job long enough to interrupt mid-run.
        let stream = ComfyUIWorkflowProvider(timeout: .seconds(600)).runWorkflow(
            config: AIWorkflowConfig(
                connection: AIConnection(baseURL: base), graph: graph,
                inputs: ["\(promptNode)/text": .string("a detailed landscape")]
            ),
            client: URLSessionNetworkClient()
        )
        var sawImage = false
        // Consume until the job is running, then break → the stream tears down and
        // the provider POSTs /interrupt. The loop must exit promptly (not hang to
        // completion) and not have produced an image.
        for try await event in stream {
            if event.type == .image { sawImage = true }
            if event.type == .progress, event.stage == "running" { break }
            if event.type == .done { break }
        }
        #expect(!sawImage) // cancelled before an image was produced
        print("[runtime.cancel] tore down after running; /interrupt issued")
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

    // MARK: - Config-driven RESTImageProvider — real Gemini / Imagen / OpenAI / Qwen

    private static let googleBase = "https://generativelanguage.googleapis.com/v1beta"
    private static let openAIBase = "https://api.openai.com/v1"
    /// DashScope has two regions — Beijing (default) and Singapore/international
    /// (`dashscope-intl`); an int'l-account key 401s on Beijing. Override via `QWEN_BASE`.
    private static let qwenBase = ProcessInfo.processInfo.environment["QWEN_BASE"]
        ?? "https://dashscope.aliyuncs.com/api/v1"

    /// One descriptor-driven provider, Google Imagen `:predict` (base64 out).
    @Test("RESTImageProvider: Imagen :predict preset", .enabled(if: geminiKey != nil))
    func restImagenLive() async throws {
        let key = try #require(Self.geminiKey)
        _ = try await runRESTLive(
            .imagen(), base: Self.googleBase, headers: ["x-goog-api-key": key],
            inputs: [
                "prompt": .string("a red fox in a snowy forest, highly detailed"),
                "aspectRatio": .string("16:9")
            ],
            label: "rest-imagen"
        )
    }

    /// The same provider adapts to Gemini's structurally-different
    /// `:generateContent` ("nano banana"). Model overridable via `GEMINI_IMAGE_MODEL`.
    @Test("RESTImageProvider: Gemini :generateContent preset", .enabled(if: geminiKey != nil))
    func restGeminiLive() async throws {
        let key = try #require(Self.geminiKey)
        let model = Self.env["GEMINI_IMAGE_MODEL"] ?? "gemini-2.5-flash-image"
        _ = try await runRESTLive(
            .geminiImage(model: model), base: Self.googleBase, headers: ["x-goog-api-key": key],
            inputs: ["prompt": .string("a red fox in a snowy forest, studio photo")],
            label: "rest-gemini"
        )
    }

    /// OpenAI-compatible `/images/generations` (Bearer auth, base64 out). Model
    /// overridable via `OPENAI_IMAGE_MODEL` (gpt-image-1 needs a verified org).
    @Test("RESTImageProvider: OpenAI /images/generations preset", .enabled(if: openAIKey != nil))
    func restOpenAILive() async throws {
        let key = try #require(Self.openAIKey)
        let model = Self.env["OPENAI_IMAGE_MODEL"] ?? "gpt-image-1"
        _ = try await runRESTLive(
            .openAICompatible(model: model), base: Self.openAIBase, headers: ["Authorization": "Bearer \(key)"],
            inputs: ["prompt": .string("a red fox in a snowy forest, studio photo")],
            label: "rest-openai"
        )
    }

    /// OpenAI **image edits** — the multipart path. Generates a source image with
    /// Imagen first, then edits it (proves file-part upload against the real API).
    @Test("RESTImageProvider: OpenAI /images/edits (multipart)", .enabled(if: openAIKey != nil && geminiKey != nil))
    func restOpenAIEditLive() async throws {
        let geminiKey = try #require(Self.geminiKey)
        let openAIKey = try #require(Self.openAIKey)
        let model = Self.env["OPENAI_IMAGE_MODEL"] ?? "gpt-image-1"
        // A real source image to edit.
        let source = try await runRESTLive(
            .imagen(), base: Self.googleBase, headers: ["x-goog-api-key": geminiKey],
            inputs: ["prompt": .string("a plain red fox portrait, studio")], label: "rest-edit-source"
        )
        let sourceBase64 = try #require(source.dataBase64)
        _ = try await runRESTLive(
            .openAIEdit(model: model), base: Self.openAIBase, headers: ["Authorization": "Bearer \(openAIKey)"],
            inputs: [
                "prompt": .string("add heavy falling snow and a winter forest background"),
                "image": .object(["dataBase64": .string(sourceBase64)])
            ],
            label: "rest-openai-edit"
        )
    }

    /// Qwen / DashScope native **async** text→image (submit → poll → URL out).
    /// Model overridable via `QWEN_IMAGE_MODEL`.
    @Test("RESTImageProvider: Qwen async submit→poll", .enabled(if: dashscopeKey != nil))
    func restQwenLive() async throws {
        let key = try #require(Self.dashscopeKey)
        let model = Self.env["QWEN_IMAGE_MODEL"] ?? "qwen-image"
        _ = try await runRESTLive(
            .qwen(model: model), base: Self.qwenBase, headers: ["Authorization": "Bearer \(key)"],
            inputs: ["prompt": .string("a red fox in a snowy forest, highly detailed")],
            label: "rest-qwen"
        )
    }

    /// `qwen-image-max` on the synchronous multimodal-generation endpoint (a
    /// different shape from the async `.qwen` preset — chat messages in, image URL
    /// under `output.choices[*].message.content[*].image` out).
    @Test("RESTImageProvider: Qwen qwen-image-max (multimodal, sync)", .enabled(if: dashscopeKey != nil))
    func restQwenImageMaxLive() async throws {
        let key = try #require(Self.dashscopeKey)
        _ = try await runRESTLive(
            .qwenImageMax(), base: Self.qwenBase, headers: ["Authorization": "Bearer \(key)"],
            inputs: ["prompt": .string("a red fox in a snowy forest, highly detailed")],
            label: "rest-qwen-image-max"
        )
    }

    @discardableResult
    private func runRESTLive(
        _ spec: RESTImageAPISpec, base: String, headers: [String: String],
        inputs: [String: JSONValue], label: String
    ) async throws -> AIGeneratedImage {
        let config = try AIWorkflowConfig(
            connection: AIConnection(baseURL: #require(URL(string: base)), headers: headers),
            graph: JSONEncoder().encode(spec),
            inputs: inputs
        )
        var image: AIGeneratedImage?
        var stages: [String] = []
        for try await event in RESTImageProvider().runWorkflow(config: config, client: URLSessionNetworkClient()) {
            switch event.type {
            case .progress: stages.append(event.stage ?? "?")
            case .image: image = event.image
            case .done: break
            }
        }
        let img = try #require(image, "no image event")
        let bytes = try #require(img.dataBase64.flatMap { Data(base64Encoded: $0) })
        #expect(bytes.count > 1000)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(label).png")
        try bytes.write(to: out)
        print("[\(label)] stages=\(stages) \(bytes.count) bytes, mime \(img.mimeType ?? "?") → \(out.path)")
        return img
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
