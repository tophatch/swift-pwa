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
/// **What routes vs. what delegates.** The image verbs and `ensureModel` route
/// by model id (`request.model` / the ensure request's `model`, `nil` ⇒ the
/// default). The text/audio verbs carry no model id, so they delegate to the
/// **default** backend. (Add a `model` field to those requests later to route
/// them too.)
public struct MultiModelImageBackend: AIBackend {
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

    /// Resolve a model id to its backend: `nil`/empty ⇒ the default; a known id
    /// ⇒ that backend; an unknown id ⇒ a clear `E_AI_GENERATION` error rather
    /// than a silent fall-through to the default (which would mask a typo).
    private func resolve(_ id: String?) throws -> any AIBackend {
        guard let id, !id.isEmpty else { return defaultBackend }
        guard let backend = byID[id] else {
            throw AIError.generationFailed("unknown model id \"\(id)\" — not one of AICapabilities.models")
        }
        return backend
    }

    // MARK: - Info (aggregate)

    public func info() async -> AICapabilities {
        // Runtime-feature flags (streaming / structured / voice cloning) and
        // audio input come from the DEFAULT backend — it's what answers the
        // non-routed text/audio verbs. The coarse modality flags and the model
        // list are the union across every routed model.
        let base = await defaultBackend.info()
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
            models: entries.map(\.info)
        )
    }

    // MARK: - Image verbs (routed by request.model)

    public func generateImage(_ request: AIGenerateImageRequest) async throws -> AIGenerateImageResult {
        try await resolve(request.model).generateImage(request)
    }

    public func generateImageStream(
        _ request: AIGenerateImageRequest
    ) -> AsyncThrowingStream<AIImageEvent, any Error> {
        let backend: any AIBackend
        do {
            backend = try resolve(request.model)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return backend.generateImageStream(request)
    }

    // MARK: - Model download (routed by the ensure request's model)

    public func ensureModel(_ request: AIEnsureModelRequest) -> AsyncThrowingStream<AIDownloadEvent, any Error> {
        let backend: any AIBackend
        do {
            backend = try resolve(request.model)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return backend.ensureModel(request)
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
}
