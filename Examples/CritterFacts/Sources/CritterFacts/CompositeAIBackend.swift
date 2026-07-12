// Only meaningful when the image-edit backend is in the graph (built with
// ai.local_onnx_runtime). Demonstrates the "an adopter composes backends behind
// the one ai.* surface" pattern the contract is designed for: text generation
// from a platform/llama backend, image *editing* (inpaint) from LaMa, and
// text→image from Stable Diffusion — all on one AIPlugin.
#if canImport(SwiftPWAImageEdit)
    import Foundation
    import SwiftPWA
    import SwiftPWAImageEdit
    import SwiftPWARemoteAI // the ComfyUI (remote) arm + its dynamic catalog

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
        /// A remote ComfyUI arm whose catalog is *discovered* (its installed
        /// checkpoints), not static — so the picker lists the models the
        /// instance actually offers. Routed by a `comfy:<checkpoint>` model id.
        private let comfy: RemoteImageBackend?
        /// Discovered-once cache of the ComfyUI catalog (a network probe), so
        /// repeated `info()` calls don't re-hit the instance.
        private var comfyCatalogCache: [AIModelInfo]?

        init(
            text: (any AIBackend)?,
            image: LaMaBackend,
            imageGen: (any AIBackend)? = nil,
            comfy: RemoteImageBackend? = nil
        ) {
            self.text = text
            self.image = image
            self.imageGen = imageGen
            self.comfy = comfy
        }

        private func isComfy(_ model: String?) -> Bool {
            model?.hasPrefix(ComfyUIProvider.modelIDPrefix) == true
        }

        /// The ComfyUI catalog, discovered once and cached. Bounded so a slow /
        /// unreachable instance doesn't stall `info()` (and thus the page's
        /// dropdown) — on timeout or error the on-device models still show.
        private func comfyCatalog() async -> [AIModelInfo] {
            if let comfyCatalogCache { return comfyCatalogCache }
            guard let comfy else { comfyCatalogCache = []; return [] }
            let discovered = (try? await withTimeout(seconds: 4) { try await comfy.discoverModels() }) ?? []
            comfyCatalogCache = discovered
            return discovered
        }

        func info() async -> AICapabilities {
            let img = await image.info()
            // Advertise text→image if a generator is present.
            let gen = await imageGen?.info()
            // The on-device switcher's catalog (LCM / SD-Turbo) plus the ComfyUI
            // instance's discovered checkpoints — local + remote in one picker.
            let discovered = await comfyCatalog()
            let catalog = (gen?.models ?? []) + discovered
            let models = catalog.isEmpty ? nil : catalog
            let hasImageGen = (gen?.imageGeneration ?? false) || (comfy != nil)
            guard let text else {
                // Image-only: still advertise editing (+ generation if present).
                return AICapabilities(
                    available: img.available || (gen?.available ?? false) || (comfy != nil),
                    backend: img.backend,
                    imageGeneration: hasImageGen,
                    imageEditing: img.imageEditing,
                    models: models
                )
            }
            let txt = await text.info()
            return AICapabilities(
                available: txt.available || img.available || (gen?.available ?? false) || (comfy != nil),
                backend: txt.backend,
                model: txt.model,
                streaming: txt.streaming,
                structuredOutput: txt.structuredOutput,
                vision: txt.vision,
                imageGeneration: hasImageGen,
                imageEditing: img.imageEditing,
                audioInput: txt.audioInput,
                audioGeneration: txt.audioGeneration,
                voiceCloning: txt.voiceCloning,
                models: models
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
            // A `comfy:<ckpt>` model id → the remote ComfyUI arm (text→image).
            if isComfy(request.model), let comfy {
                return try await comfy.generateImage(request)
            }
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
            if request.model?.hasPrefix(ComfyUIProvider.modelIDPrefix) == true, let comfy {
                return comfy.generateImageStream(request)
            }
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
            case let .some(id) where id.hasPrefix(ComfyUIProvider.modelIDPrefix):
                // A remote ComfyUI model — nothing to download (ready).
                guard let comfy else {
                    return AsyncThrowingStream { $0.finish(throwing: AIError.unsupportedPlatform("no ComfyUI arm")) }
                }
                return comfy.ensureModel(request)
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

    /// Run `operation`, throwing `CancellationError` if it takes longer than
    /// `seconds` — so a slow/unreachable remote probe (ComfyUI discovery) can't
    /// stall `info()`. The loser task is cancelled.
    private func withTimeout<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
#endif
