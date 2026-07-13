import Foundation

/// Adapts **any ``AIBackend``** into a runtime, JS-reachable ``AIWorkflowProvider``,
/// so an on-device image model (Stable Diffusion, LaMa) answers `ai.describeInputs`
/// / `ai.run` through the *same* surface — and the same JS UI — as a ComfyUI graph
/// or Imagen. One generic adapter covers every current and future `AIBackend`: the
/// backends stay unaware of the workflow surface, and this lives in Core (both
/// `AIBackend` and `AIWorkflowProvider` do), so wrapping a backend pulls in no extra
/// target.
///
/// The schema is **fixed** and derived from the backend's ``AICapabilities`` — a
/// text→image backend advertises `prompt` / `steps` / `guidanceScale` / `seed` /
/// `count`; an image-editing backend adds `image` / `mask`; a pure inpainter (LaMa,
/// `imageEditing` only) advertises just `image` / `mask`. No graph, no network
/// probe (so `describeInputs` is never `degraded`). `runWorkflow` maps the run's
/// `inputs` onto an ``AIGenerateImageRequest`` and bridges the backend's
/// `generateImageStream` — its per-step `progress` events become `.progress`, its
/// terminal images become `.image`(s), then `.done`. There's no `jobId` / recovery
/// (on-device runs aren't re-attachable) and the connection is ignored (the plugin
/// passes a placeholder).
public struct AIBackendWorkflowProvider: AIWorkflowProvider {
    public let providerID: String
    private let backend: any AIBackend

    /// - Parameters:
    ///   - providerID: the id `ai.run` / `ai.describeInputs` route on (e.g.
    ///     `"stable-diffusion"` or `"lama"`). Distinct per wrapped backend.
    ///   - backend: the on-device backend to expose.
    public init(providerID: String, backend: any AIBackend) {
        self.providerID = providerID
        self.backend = backend
    }

    public func describeInputs(
        config _: AIWorkflowConfig,
        client _: any NetworkClient
    ) async throws -> AIInputSchema {
        let caps = await backend.info()
        var fields: [AIInputField] = []

        if let models = caps.models, models.count > 1 {
            fields.append(AIInputField(
                key: "model", label: "Model", type: .enum,
                value: .string(models.first?.id ?? ""), options: models.map(\.id)
            ))
        }
        if caps.imageGeneration {
            fields.append(AIInputField(key: "prompt", label: "Prompt", type: .text))
            fields.append(AIInputField(key: "negativePrompt", label: "Negative prompt", type: .text))
            fields.append(AIInputField(key: "steps", label: "Steps", type: .int, min: 1, step: 1))
            fields.append(AIInputField(key: "guidanceScale", label: "Guidance scale", type: .float, min: 0))
            fields.append(AIInputField(key: "seed", label: "Seed", type: .seed))
            fields.append(AIInputField(
                key: "count",
                label: "Number of images",
                type: .int,
                value: .number(1),
                min: 1,
                step: 1
            ))
        }
        if caps.imageEditing {
            fields.append(AIInputField(key: "image", label: "Image", type: .image, isImage: true))
            fields.append(AIInputField(key: "mask", label: "Mask", type: .mask, isImage: true))
        }
        return AIInputSchema(inputs: fields, degraded: false)
    }

    public func runWorkflow(
        config: AIWorkflowConfig,
        client _: any NetworkClient
    ) -> AsyncThrowingStream<AIRunEvent, any Error> {
        let backend = backend
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let inputs = config.inputs
                    let request = AIGenerateImageRequest(
                        prompt: Self.string(inputs["prompt"]),
                        negativePrompt: Self.string(inputs["negativePrompt"]),
                        steps: Self.int(inputs["steps"]),
                        seed: Self.int(inputs["seed"]),
                        count: Self.int(inputs["count"]),
                        outputDirectory: config.outputDirectory,
                        image: Self.image(inputs["image"]),
                        mask: Self.image(inputs["mask"]),
                        guidanceScale: Self.double(inputs["guidanceScale"]),
                        model: Self.string(inputs["model"])
                    )
                    for try await event in backend.generateImageStream(request) {
                        try Task.checkCancellation()
                        switch event.type {
                        case "progress":
                            continuation.yield(.progress(
                                stage: "running",
                                value: event.step.map(Double.init),
                                max: event.totalSteps.map(Double.init)
                            ))
                        case "done":
                            for image in event.images ?? [] { continuation.yield(.image(image)) }
                        default:
                            break
                        }
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Input coercion

    private static func string(_ value: JSONValue?) -> String? {
        if case let .string(string)? = value, !string.isEmpty { return string }
        return nil
    }

    private static func int(_ value: JSONValue?) -> Int? {
        switch value {
        case let .number(number)?: Int(number)
        case let .string(string)?: Int(string)
        default: nil
        }
    }

    private static func double(_ value: JSONValue?) -> Double? {
        switch value {
        case let .number(number)?: number
        case let .string(string)?: Double(string)
        default: nil
        }
    }

    /// Build an `AIImage` from a `{ dataBase64 }` / `{ path }` (+ optional
    /// `mimeType`) input value — the carrier the JS side sends image/mask inputs as.
    private static func image(_ value: JSONValue?) -> AIImage? {
        guard case let .object(object)? = value else { return nil }
        let mime = string(object["mimeType"])
        if case let .string(base64)? = object["dataBase64"], !base64.isEmpty {
            return AIImage(dataBase64: base64, mimeType: mime)
        }
        if case let .string(path)? = object["path"], !path.isEmpty {
            return AIImage(path: path, mimeType: mime)
        }
        return nil
    }
}
