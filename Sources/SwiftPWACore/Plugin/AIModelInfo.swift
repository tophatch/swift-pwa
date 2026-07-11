import Foundation

// MARK: - Model catalog (for a runtime model/backend switcher)

/// What a model can do, as a set rather than a fixed pair of bools — so one
/// model list can carry text, image, vision, and audio backends alike, and new
/// purposes are added without a struct change. Covers the standard multimodal
/// capabilities the `ai.*` / `ai.vision.*` surfaces already span.
///
/// The raw values are the strings JS sees over the bridge
/// (`model.capabilities.includes('inpaint')`), so keep them stable.
public enum AIModelCapability: String, Sendable, Codable, CaseIterable {
    // Text
    case textGeneration = "text-generation" // chat / completion
    case textEmbedding = "text-embedding" // vectors for RAG / semantic search
    // Image out
    case imageGeneration = "image-generation" // text→image
    case imageEdit = "image-edit" // img2img / prompt+image
    case inpaint // image+mask
    /// Image understanding (image *in*) — segmentation, detection, OCR, captioning.
    case vision
    // Audio
    case speechToText = "speech-to-text" // transcription / ASR
    case textToSpeech = "text-to-speech" // TTS
    case audioGeneration = "audio-generation" // music / sfx / general audio
}

/// Runtime availability of a model, unified across local and remote.
///
/// A `downloaded: Bool` + `sizeBytes` pair can't express a cloud model (never
/// "downloaded", no size) or a backend that's present-but-unusable (missing API
/// key, offline), so availability is a tagged enum. It encodes to a
/// JS-discriminated union — `{ kind, bytes?, reason? }` — rather than Swift's
/// synthesized nested form, so a page can branch on `availability.kind`.
public enum AIModelAvailability: Sendable, Codable, Equatable {
    /// Usable right now: a remote model whose service is reachable, or a local
    /// model already on disk.
    case ready
    /// A local model not yet fetched — call `ai.ensureModel`. `bytes` is the
    /// download size when known.
    case downloadable(bytes: Int64?)
    /// Present but not usable until the user does something (adds an API key,
    /// goes online, unlocks a region). `reason` is human-facing.
    case needsSetup(reason: String)

    /// Whether the model is usable now or after a one-time download — mirrors
    /// `AICapabilities.available` semantics (a *downloadable* model still
    /// counts as available; only `needsSetup` gates it out).
    public var isAvailableNow: Bool {
        switch self {
        case .ready, .downloadable: true
        case .needsSetup: false
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, bytes, reason }
    private enum Kind: String, Codable { case ready, downloadable, needsSetup }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ready:
            try c.encode(Kind.ready, forKey: .kind)
        case let .downloadable(bytes):
            try c.encode(Kind.downloadable, forKey: .kind)
            try c.encodeIfPresent(bytes, forKey: .bytes)
        case let .needsSetup(reason):
            try c.encode(Kind.needsSetup, forKey: .kind)
            try c.encode(reason, forKey: .reason)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .ready:
            self = .ready
        case .downloadable:
            self = try .downloadable(bytes: c.decodeIfPresent(Int64.self, forKey: .bytes))
        case .needsSetup:
            self = try .needsSetup(reason: c.decode(String.self, forKey: .reason))
        }
    }
}

/// One entry in `AICapabilities.models` — a model (local or remote) a
/// multi-model backend can serve, described richly enough to drive a picker:
/// what it does (`capabilities`), whether it's usable now (`availability`),
/// on-device vs cloud (`offlineCapable`), and its licence.
///
/// Modality-agnostic on purpose — an `AIModelInfo`, not an image-specific type —
/// so the same list can present text, image, vision, and audio models in one
/// dropdown.
public struct AIModelInfo: Sendable, Codable, Equatable {
    /// Stable id — the string an adopter routes on (matches `request.model` and
    /// `ai.ensureModel`'s `model` hint). E.g. `"lcm-dreamshaper"`, `"cloud-sdxl"`.
    public let id: String
    /// Human-facing label for the picker, e.g. `"LCM Dreamshaper"`.
    public let label: String
    /// Everything this model can do.
    public let capabilities: Set<AIModelCapability>
    /// Whether it's usable now, needs a download, or needs setup.
    public let availability: AIModelAvailability
    /// On-device (no network) vs cloud — lets the picker badge the trade-off
    /// the user switches on (fast/offline/free vs quality/online/paid).
    public let offlineCapable: Bool
    /// Licence string for a commercial-use filter, e.g. `"OpenRAIL-M"`,
    /// `"Stability Non-Commercial"`. `nil` when not applicable / unknown.
    public let license: String?

    public init(
        id: String,
        label: String,
        capabilities: Set<AIModelCapability>,
        availability: AIModelAvailability,
        offlineCapable: Bool,
        license: String? = nil
    ) {
        self.id = id
        self.label = label
        self.capabilities = capabilities
        self.availability = availability
        self.offlineCapable = offlineCapable
        self.license = license
    }
}
