// Only meaningful when the image-edit backend is in the graph (built with
// ai.local_onnx_runtime). Demonstrates the "an adopter composes backends behind
// the one ai.* surface" pattern the contract is designed for: text generation
// from a platform/llama backend, image editing from LaMa — one AIPlugin.
#if canImport(SwiftPWAImageEdit)
    import Foundation
    import SwiftPWA
    import SwiftPWAImageEdit

    /// Routes the `ai.*` surface across two backends by capability: text
    /// (`generate` / `generateStream` / `generateJSON`) to `text`, image editing
    /// (`generateImage`) to `image` (LaMa). `ai.ensureModel` routes by the
    /// request's `model` hint — `"inpaint"` / `"lama"` drives the LaMa download,
    /// anything else the text backend's. This is example code, not part of the
    /// framework: `AIPlugin` takes one backend, and *this* is how you give it
    /// more than one purpose.
    actor CompositeAIBackend: AIBackend {
        private let text: (any AIBackend)?
        private let image: LaMaBackend

        init(text: (any AIBackend)?, image: LaMaBackend) {
            self.text = text
            self.image = image
        }

        func info() async -> AICapabilities {
            let img = await image.info()
            guard let text else {
                // Image-only: still advertise editing.
                return AICapabilities(available: img.available, backend: img.backend, imageEditing: img.imageEditing)
            }
            let txt = await text.info()
            return AICapabilities(
                available: txt.available || img.available,
                backend: txt.backend,
                model: txt.model,
                streaming: txt.streaming,
                structuredOutput: txt.structuredOutput,
                vision: txt.vision,
                imageGeneration: img.imageGeneration,
                imageEditing: img.imageEditing,
                audioInput: txt.audioInput,
                audioGeneration: txt.audioGeneration,
                voiceCloning: txt.voiceCloning
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
            try await image.generateImage(request)
        }

        nonisolated func ensureModel(_ request: AIEnsureModelRequest) -> AsyncThrowingStream<AIDownloadEvent, any Error> {
            let wantsImage = (request.model == "inpaint" || request.model == "lama")
            if wantsImage { return image.ensureModel(request) }
            guard let text else {
                return AsyncThrowingStream { $0.finish(throwing: AIError.unsupportedPlatform("no text backend")) }
            }
            return text.ensureModel(request)
        }
    }
#endif
