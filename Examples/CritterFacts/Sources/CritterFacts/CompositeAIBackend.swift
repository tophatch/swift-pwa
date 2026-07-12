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
        /// A remote **cloud** arm: Google Imagen. Unlike the others its API key
        /// isn't baked in — it's read at runtime from the OS secure store (the
        /// `secrets.*` plugin). So its models advertise **`needsSetup`** until a
        /// key exists and flip to **`ready`** once one is stored: the composite
        /// (which owns the store) computes that availability at `info()` time,
        /// since only the app knows the store / key name. Routed by the plain
        /// Imagen model ids (`imagen-4.0-generate-001`, …).
        private let imagen: RemoteImageBackend?
        /// Whether an Imagen API key is currently stored — drives the `needsSetup`
        /// vs `ready` availability of the Imagen models. Injected (not a direct
        /// `SecretStore` dep) so this example file stays store-agnostic.
        private let imagenKeyPresent: (@Sendable () async -> Bool)?
        /// The Imagen model ids, for routing `generateImage` / `ensureModel`.
        private let imagenModelIDs: Set<String>

        init(
            text: (any AIBackend)?,
            image: LaMaBackend,
            imageGen: (any AIBackend)? = nil,
            comfy: RemoteImageBackend? = nil,
            imagen: RemoteImageBackend? = nil,
            imagenKeyPresent: (@Sendable () async -> Bool)? = nil
        ) {
            self.text = text
            self.image = image
            self.imageGen = imageGen
            self.comfy = comfy
            self.imagen = imagen
            self.imagenKeyPresent = imagenKeyPresent
            imagenModelIDs = Set((imagen?.models ?? []).map(\.id))
        }

        private func isComfy(_ model: String?) -> Bool {
            model?.hasPrefix(ComfyUIProvider.modelIDPrefix) == true
        }

        private func isImagen(_ model: String?) -> Bool {
            guard let model else { return false }
            return imagenModelIDs.contains(model)
        }

        /// The Imagen catalog with availability computed from the stored key:
        /// `ready` when a key exists, else `needsSetup` (the page then shows a
        /// key field instead of the generate button — see web/generate.html).
        private func imagenCatalog() async -> [AIModelInfo] {
            guard let imagen else { return [] }
            let present = await imagenKeyPresent?() ?? true
            let availability: AIModelAvailability = present
                ? .ready
                : .needsSetup(reason: "Add a Google AI API key to use Imagen")
            return imagen.models.map {
                AIModelInfo(
                    id: $0.id, label: $0.label, capabilities: $0.capabilities,
                    availability: availability, offlineCapable: $0.offlineCapable, license: $0.license
                )
            }
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
            // On-device switcher (LCM / SD-Turbo) + discovered ComfyUI checkpoints
            // + the cloud Imagen models (needsSetup/ready per the stored key).
            let catalog = (gen?.models ?? []) + discovered + (await imagenCatalog())
            let models = catalog.isEmpty ? nil : catalog
            let hasImageGen = (gen?.imageGeneration ?? false) || (comfy != nil) || (imagen != nil)
            guard let text else {
                // Image-only: still advertise editing (+ generation if present).
                return AICapabilities(
                    available: img.available || (gen?.available ?? false) || (comfy != nil) || (imagen != nil),
                    backend: img.backend,
                    imageGeneration: hasImageGen,
                    imageEditing: img.imageEditing,
                    models: models
                )
            }
            let txt = await text.info()
            return AICapabilities(
                available: txt.available || img.available || (gen?.available ?? false)
                    || (comfy != nil) || (imagen != nil),
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
            // An Imagen model id → the remote cloud arm (text→image).
            if isImagen(request.model), let imagen {
                return try await imagen.generateImage(request)
            }
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
            if imagenModelIDs.contains(request.model ?? ""), let imagen {
                return imagen.generateImageStream(request)
            }
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
            case let .some(id) where imagenModelIDs.contains(id):
                // A remote cloud model — nothing to download (ready once a key
                // is set; the page only reaches here for a `ready` model).
                guard let imagen else {
                    return AsyncThrowingStream { $0.finish(throwing: AIError.unsupportedPlatform("no Imagen arm")) }
                }
                return imagen.ensureModel(request)
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
