import Foundation

/// A composite `AIBackend` that routes among several backends by model id —
/// the shipped version of the "one `ai.*` surface, several backends" pattern
/// (`Examples/CritterFacts`'s `CompositeAIBackend` demonstrates it example-side).
///
/// Every adopter that offers a runtime model switcher otherwise hand-rolls the
/// same router: hold N backends, switch `generateImage` / `generateImageStream`
/// / `ensureModel` on `request.model`, and aggregate each one's `AIModelInfo`
/// into `ai.info`'s `models` list. This is that router, once.
///
/// **Local and remote.** A routed backend is just an `AIBackend` — it can run
/// an on-device ONNX model *or* call a cloud image API. So a dropdown offering
/// "LCM (on-device)" and "SDXL (cloud)" is one `MultiModelImageBackend` over the
/// two, and `request.model` names the route (a whole backend, local or remote),
/// not merely a weights file. Each model's `AIModelInfo` carries the metadata a
/// picker needs — capabilities, `availability`, `offlineCapable`, `license`.
///
/// **Memory: one model resident at a time.** On-device image models are large
/// (a fp16 Stable-Diffusion pipeline is ~2 GB of session weights, held until
/// released). Loading a second while the first is still resident OOMs a phone —
/// which is why a naive switcher crashes on the *second* model. So when a
/// generate routes to a **different** model than last time, this first calls
/// `unload()` on the previously-active backend (freeing its sessions) before the
/// new one loads lazily. A backend with nothing to free inherits the no-op
/// `unload()`, so remote backends cost nothing here.
///
/// **What routes vs. what delegates.** The image verbs route by model id
/// (`request.model`, `nil` ⇒ the default). `ensureModel` routes by id too but
/// does *not* trigger an unload — a download streams to disk and loads no
/// sessions. The text/audio verbs carry no model id, so they delegate to the
/// **default** backend. (Add a `model` field to those requests later to route
/// them too.)
public final class MultiModelImageBackend: AIBackend, @unchecked Sendable {
    /// One routable model: the adopter-declared `AIModelInfo` (the id JS routes
    /// on, plus label / capabilities / availability / licence for the picker)
    /// paired with the backend that serves it.
    public struct Entry: Sendable {
        public let info: AIModelInfo
        public let backend: any AIBackend

        public init(_ info: AIModelInfo, _ backend: any AIBackend) {
            self.info = info
            self.backend = backend
        }
    }

    private let entries: [Entry]
    private let byID: [String: any AIBackend]
    private let defaultID: String
    private let defaultBackend: any AIBackend

    /// The model whose sessions are (or are being) loaded — so a switch to a
    /// different model can free the old one first. Guarded by `lock`.
    private let lock = NSLock()
    private var activeID: String?

    /// - Parameters:
    ///   - entries: the models to serve, in the order a picker should show
    ///     them. Ids should be unique; a later duplicate wins the routing map.
    ///   - defaultID: the id used when a request names no model. Must be one of
    ///     `entries` (falls back to the first entry if not).
    public init(_ entries: [Entry], default defaultID: String) {
        precondition(!entries.isEmpty, "MultiModelImageBackend needs at least one entry")
        self.entries = entries
        self.defaultID = defaultID
        var map: [String: any AIBackend] = [:]
        for entry in entries { map[entry.info.id] = entry.backend }
        byID = map
        defaultBackend = map[defaultID] ?? entries[0].backend
    }

    // MARK: - Routing

    /// Resolve a model id to its concrete id + backend: `nil`/empty ⇒ the
    /// default; a known id ⇒ that backend; an unknown id ⇒ a clear
    /// `E_AI_GENERATION` error rather than a silent fall-through to the default
    /// (which would mask a typo).
    private func resolve(_ model: String?) throws -> (id: String, backend: any AIBackend) {
        let id = (model.map { !$0.isEmpty } == true) ? model! : defaultID
        guard let backend = byID[id] else {
            throw AIError.generationFailed("unknown model id \"\(id)\" — not one of AICapabilities.models")
        }
        return (id, backend)
    }

    /// Make `id` the active model, releasing the previously-active one's cached
    /// sessions first (only when actually switching). Awaited before the new
    /// model loads, so peak memory is one model, not two.
    private func makeActive(_ id: String) async {
        var toUnload: (any AIBackend)?
        lock.withLock {
            if activeID != id {
                if let previous = activeID { toUnload = byID[previous] }
                activeID = id
            }
        }
        await toUnload?.unload()
    }

    // MARK: - Image verbs (routed by request.model)

    public func generateImage(_ request: AIGenerateImageRequest) async throws -> AIGenerateImageResult {
        let (id, backend) = try resolve(request.model)
        await makeActive(id)
        return try await backend.generateImage(request)
    }

    public func generateImageStream(
        _ request: AIGenerateImageRequest
    ) -> AsyncThrowingStream<AIImageEvent, any Error> {
        let resolved: (id: String, backend: any AIBackend)
        do {
            resolved = try resolve(request.model)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                await makeActive(resolved.id) // free the previous model before this one loads
                do {
                    for try await event in resolved.backend.generateImageStream(request) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Model download (routed by the ensure request's model)

    public func ensureModel(_ request: AIEnsureModelRequest) -> AsyncThrowingStream<AIDownloadEvent, any Error> {
        let backend: any AIBackend
        do {
            backend = try resolve(request.model).backend
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        // No makeActive here: a download streams to disk and loads no sessions,
        // so it needn't evict the resident model.
        return backend.ensureModel(request)
    }

    // MARK: - Resource release

    /// Unload *every* routed backend (e.g. on a memory-pressure signal). The
    /// per-switch eviction keeps one model resident; this frees that one too.
    public func unload() async {
        lock.withLock { activeID = nil }
        for entry in entries { await entry.backend.unload() }
    }

    // MARK: - Text / audio verbs (delegate to the default backend)

    public func generate(_ request: AIGenerateRequest) async throws -> AIGenerateResult {
        try await defaultBackend.generate(request)
    }

    public func generateStream(_ request: AIGenerateRequest) -> AsyncThrowingStream<AIChunk, any Error> {
        defaultBackend.generateStream(request)
    }

    public func generateJSON(_ request: AIGenerateJSONRequest) async throws -> JSONValue {
        try await defaultBackend.generateJSON(request)
    }

    public func generateAudio(_ request: AIGenerateAudioRequest) async throws -> AIGenerateAudioResult {
        try await defaultBackend.generateAudio(request)
    }

    public func generateAudioStream(
        _ request: AIGenerateAudioRequest
    ) -> AsyncThrowingStream<AIAudioChunk, any Error> {
        defaultBackend.generateAudioStream(request)
    }

    // MARK: - Info (aggregate)

    public func info() async -> AICapabilities {
        // Runtime-feature flags (streaming / structured / voice cloning) and
        // audio input come from the DEFAULT backend — it's what answers the
        // non-routed text/audio verbs. The coarse modality flags and the model
        // list are the union across every routed model.
        let base = await defaultBackend.info()
        // The provider of whichever backend is currently *resident* — the router
        // keeps one model loaded at a time, so the default backend's answer is
        // only right until the first switch.
        var residentProvider: String?
        if let resident = lock.withLock({ activeID }).flatMap({ byID[$0] }) {
            residentProvider = await resident.info().provider
        }
        let caps = entries.reduce(into: Set<AIModelCapability>()) { $0.formUnion($1.info.capabilities) }
        let available = entries.contains { $0.info.availability.isAvailableNow }
        return AICapabilities(
            available: available,
            backend: AIBackendID.multiModel,
            model: defaultID,
            streaming: base.streaming,
            structuredOutput: base.structuredOutput,
            vision: caps.contains(.vision) || base.vision,
            imageGeneration: caps.contains(.imageGeneration),
            imageEditing: caps.contains(.imageEdit) || caps.contains(.inpaint),
            audioInput: caps.contains(.speechToText) || base.audioInput,
            audioGeneration: caps.contains(.textToSpeech) || caps.contains(.audioGeneration),
            voiceCloning: base.voiceCloning,
            models: entries.map(\.info),
            // Falls back to the default backend's when nothing has been routed.
            provider: residentProvider ?? base.provider
        )
    }
}
