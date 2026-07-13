import Foundation
import SwiftPWACore

/// Exposes a single **imported ComfyUI workflow** as an `ai.*` image model: a
/// ``RemoteImageProvider`` that maps the standard ``AIGenerateImageRequest``
/// fields (`prompt` / `negativePrompt` / `seed` / `image` / `mask` / `width` /
/// `height` / `steps` / `guidanceScale`) onto the workflow's nodes and runs it
/// through ``ComfyUIProvider/runWorkflow(graph:inputs:bindings:client:outputDirectory:)``.
///
/// This is the turnkey rung of the runner: for a workflow whose inputs line up
/// with the request fields, it plugs straight into the shipped
/// `MultiModelImageBackend` switcher next to on-device and other remote models —
/// `ai.generateImage({ model: "comfy:workflow:…", prompt, image })` routes here —
/// with no ComfyUI-specific JS. For arbitrary inputs (two images, numeric params
/// a request doesn't model) call `runWorkflow` directly instead.
///
/// The app owns importing / storing / selecting the graph; this wraps *one*
/// chosen graph. Derive the ``FieldBindings`` from
/// ``ComfyUIProvider/inspectWorkflow(graph:client:titledOnly:)`` (each
/// `WorkflowInput` carries its `(nodeID, inputName)` location) or hand-write them.
///
/// ```swift
/// let provider = ComfyWorkflowProvider(
///     baseURL: URL(string: "http://nas.local:8188")!,
///     graph: importedGraphJSON,
///     fields: .init(prompt: .at(node: "108", input: "text"),
///                   seed: .at(node: "106", input: "seed")),
///     model: AIModelInfo(id: "comfy:workflow:qwen-txt2img", label: "Qwen-Image (ComfyUI)",
///                        capabilities: [.imageGeneration], availability: .ready,
///                        offlineCapable: false))
/// let backend = RemoteImageBackend(provider: provider, client: net)
/// ```
public struct ComfyWorkflowProvider: RemoteImageProvider {
    /// Where each standard request field lands in the workflow graph. Any field
    /// left `nil` isn't driven — the graph keeps its baked value. Fan-out and
    /// image upload work exactly as in `runWorkflow` (an `image`/`mask` binding
    /// should be an `.imageAt`).
    public struct FieldBindings: Sendable {
        public var prompt: WorkflowBinding?
        public var negativePrompt: WorkflowBinding?
        public var seed: WorkflowBinding?
        public var image: WorkflowBinding?
        public var mask: WorkflowBinding?
        public var width: WorkflowBinding?
        public var height: WorkflowBinding?
        public var steps: WorkflowBinding?
        public var guidanceScale: WorkflowBinding?

        public init(
            prompt: WorkflowBinding? = nil,
            negativePrompt: WorkflowBinding? = nil,
            seed: WorkflowBinding? = nil,
            image: WorkflowBinding? = nil,
            mask: WorkflowBinding? = nil,
            width: WorkflowBinding? = nil,
            height: WorkflowBinding? = nil,
            steps: WorkflowBinding? = nil,
            guidanceScale: WorkflowBinding? = nil
        ) {
            self.prompt = prompt
            self.negativePrompt = negativePrompt
            self.seed = seed
            self.image = image
            self.mask = mask
            self.width = width
            self.height = height
            self.steps = steps
            self.guidanceScale = guidanceScale
        }
    }

    public let models: [AIModelInfo]
    public let backendID: String

    private let graph: Data
    private let fields: FieldBindings
    private let comfy: ComfyUIProvider

    /// - Parameters:
    ///   - baseURL: the ComfyUI origin.
    ///   - graph: the imported API-format graph JSON.
    ///   - fields: which request field drives which node input.
    ///   - model: the catalog entry to advertise (its `capabilities` decide
    ///     whether `ai.info` reports `imageGeneration` / `imageEditing`).
    ///   - backendID: provenance stamped on results; defaults to `comfyui-workflow`.
    ///   - clientID / timeout: forwarded to the underlying ``ComfyUIProvider``.
    public init(
        baseURL: URL,
        graph: Data,
        fields: FieldBindings,
        model: AIModelInfo,
        backendID: String = "comfyui-workflow",
        clientID: String = UUID().uuidString,
        timeout: Duration = .seconds(300)
    ) {
        self.graph = graph
        self.fields = fields
        models = [model]
        self.backendID = backendID
        comfy = ComfyUIProvider(baseURL: baseURL, clientID: clientID, timeout: timeout)
    }

    public func generateImage(
        _ request: AIGenerateImageRequest,
        client: any NetworkClient
    ) async throws -> [AIGeneratedImage] {
        var inputs: [String: WorkflowInputValue] = [:]
        var bindings: [String: WorkflowBinding] = [:]
        func bind(_ name: String, _ binding: WorkflowBinding?, _ value: WorkflowInputValue?) {
            guard let binding, let value else { return }
            bindings[name] = binding
            inputs[name] = value
        }
        bind("prompt", fields.prompt, request.prompt.map(WorkflowInputValue.text))
        bind("negativePrompt", fields.negativePrompt, request.negativePrompt.map(WorkflowInputValue.text))
        bind("width", fields.width, request.width.map(WorkflowInputValue.int))
        bind("height", fields.height, request.height.map(WorkflowInputValue.int))
        bind("steps", fields.steps, request.steps.map(WorkflowInputValue.int))
        bind("guidanceScale", fields.guidanceScale, request.guidanceScale.map(WorkflowInputValue.float))
        // Seed is bound even when the request omits it, so runWorkflow's
        // randomize-per-run policy applies (a baked graph seed would otherwise
        // repeat the same image every call).
        if let binding = fields.seed {
            bindings["seed"] = binding
            inputs["seed"] = .seed(request.seed)
        }
        if let binding = fields.image, let image = request.image {
            bindings["image"] = binding
            inputs["image"] = try .image(Self.bytes(of: image))
        }
        if let binding = fields.mask, let mask = request.mask {
            bindings["mask"] = binding
            inputs["mask"] = try .mask(Self.bytes(of: mask))
        }
        return try await comfy.runWorkflow(
            graph: graph,
            inputs: inputs,
            bindings: bindings,
            client: client,
            outputDirectory: request.outputDirectory
        )
    }

    /// Resolve an `AIImage`'s bytes from its inline base64 or on-disk `path`.
    private static func bytes(of image: AIImage) throws -> Data {
        if let base64 = image.dataBase64, let data = Data(base64Encoded: base64) {
            return data
        }
        if let path = image.path {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        }
        throw AIError.generationFailed("ComfyUI workflow image input has neither dataBase64 nor path")
    }
}
