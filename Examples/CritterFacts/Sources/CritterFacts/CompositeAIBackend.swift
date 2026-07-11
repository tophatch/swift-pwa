// Only meaningful when the image-edit backend is in the graph (built with
// ai.local_onnx_runtime). Demonstrates the "an adopter composes backends behind
// the one ai.* surface" pattern the contract is designed for: text generation
// from a platform/llama backend, image *editing* (inpaint) from LaMa, and
// text→image from Stable Diffusion — all on one AIPlugin.
#if canImport(SwiftPWAImageEdit)
    import Foundation
    import SwiftPWA
    import SwiftPWAImageEdit

    /// Routes the `ai.*` surface across up to three backends by capability:
    /// text (`generate` / `generateStream` / `generateJSON`) to `text`, and
    /// `generateImage` split by whether the request carries a source `image` —
    /// present ⇒ editing/inpaint (`image`, LaMa); absent ⇒ text→image
    /// (`imageGen`). `imageGen` is itself a `MultiModelImageBackend` here, so a
    /// bare prompt's `request.model` picks *which* image model (LCM vs SD-Turbo).
    /// `ai.ensureModel` routes by the request's `model`: `"inpaint"` / `"lama"`
    /// → LaMa; any other non-empty id → the image-generation switcher (which
    /// resolves the concrete model); `nil` / `""` → the text backend's model.
    /// `info().models` surfaces the switcher's catalog so a page can build a
    /// picker. This is example code, not part of the framework: `AIPlugin` takes
    /// one backend, and *this* is how you give it more than one purpose.
    /// `imageGen` is kept as a plain `any AIBackend` so this file needs no
    /// Stable-Diffusion import — the caller (see `configure`) supplies it only
    /// where the SD target is in the build.
    actor CompositeAIBackend: AIBackend {
        private let text: (any AIBackend)?
        private let image: LaMaBackend
        private let imageGen: (any AIBackend)?

        init(text: (any AIBackend)?, image: LaMaBackend, imageGen: (any AIBackend)? = nil) {
            self.text = text
            self.image = image
            self.imageGen = imageGen
        }

        func info() async -> AICapabilities {
            let img = await image.info()
            // Advertise text→image if a generator is present.
            let gen = await imageGen?.info()
            guard let text else {
                // Image-only: still advertise editing (+ generation if present).
                return AICapabilities(
                    available: img.available || (gen?.available ?? false),
                    backend: img.backend,
                    imageGeneration: gen?.imageGeneration ?? false,
                    imageEditing: img.imageEditing,
                    models: gen?.models
                )
            }
            let txt = await text.info()
            return AICapabilities(
                available: txt.available || img.available || (gen?.available ?? false),
                backend: txt.backend,
                model: txt.model,
                streaming: txt.streaming,
                structuredOutput: txt.structuredOutput,
                vision: txt.vision,
                imageGeneration: gen?.imageGeneration ?? false,
                imageEditing: img.imageEditing,
                audioInput: txt.audioInput,
                audioGeneration: txt.audioGeneration,
                voiceCloning: txt.voiceCloning,
                // The switcher's model catalog (LCM / SD-Turbo), so the page can
                // build a picker; nil when this build has no image generator.
                models: gen?.models
            )
        }

        func generate(_ request: AIGenerateRequest) async throws -> AIGenerateResult {
            guard let text else { throw AIError.unsupportedPlatform("no text backend in this build") }
            return try await text.generate(request)
        }

        nonisolated func generateStream(_ request: AIGenerateRequest) -> AsyncThrowingStream<AIChunk, any Error> {
            guard let text else {
                return AsyncThrowingStream { $0.finish(throwing: AIError.unsupportedPlatform("no text backend")) }
            }
            return text.generateStream(request)
        }

        func generateJSON(_ request: AIGenerateJSONRequest) async throws -> JSONValue {
            guard let text else { throw AIError.unsupportedPlatform("no text backend in this build") }
            return try await text.generateJSON(request)
        }

        func generateImage(_ request: AIGenerateImageRequest) async throws -> AIGenerateImageResult {
            // A source `image` means an edit (inpaint) → LaMa; a bare prompt
            // means text→image → the SD generator (if this build has one).
            if request.image == nil, let imageGen {
                return try await imageGen.generateImage(request)
            }
            return try await image.generateImage(request)
        }

        nonisolated func generateImageStream(_ request: AIGenerateImageRequest)
            -> AsyncThrowingStream<AIImageEvent, any Error>
        {
            if request.image == nil, let imageGen {
                return imageGen.generateImageStream(request) // SD reports per-step progress
            }
            return image.generateImageStream(request)
        }

        nonisolated func ensureModel(_ request: AIEnsureModelRequest)
            -> AsyncThrowingStream<AIDownloadEvent, any Error>
        {
            switch request.model {
            case "inpaint", "lama":
                return image.ensureModel(request)
            case let .some(id) where !id.isEmpty:
                // Any other non-empty id is an image-generation model
                // ("lcm-dreamshaper" / "sd-turbo") — hand it to the switcher,
                // which resolves the concrete backend (or errors on an unknown id).
                guard let imageGen else {
                    return AsyncThrowingStream {
                        $0.finish(throwing: AIError.unsupportedPlatform("no image-generation backend in this build"))
                    }
                }
                return imageGen.ensureModel(request)
            default:
                // nil / "" → the text model (index.html sends `{}`).
                guard let text else {
                    return AsyncThrowingStream { $0.finish(throwing: AIError.unsupportedPlatform("no text backend")) }
                }
                return text.ensureModel(request)
            }
        }
    }
#endif
