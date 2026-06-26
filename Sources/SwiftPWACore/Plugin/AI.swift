import Foundation

/// An on-device (or otherwise native) LLM backend. Defined in Core
/// (dependency-free) so `AIPlugin` can offer the `ai.*` command set
/// without `SwiftPWACore` taking on a model-runtime dependency: the
/// concrete implementations (Apple Foundation Models, Android Gemini
/// Nano, Windows Phi Silica, or the portable Gemma fallback via
/// MLX / MediaPipe / ONNX / llama.cpp) live in optional backend targets
/// and are injected by apps — `ctx.use(AIPlugin(MyBackend()))`, exactly
/// the way `ArchiveExtractor` / `ZIPExtractor` work for `fs.*`.
///
/// Only `info()` and `generate(_:)` are required. The streaming,
/// structured-JSON, and model-download surfaces have default
/// implementations so a backend that does the bare minimum (and every
/// test double) still compiles:
/// - `generateStream` defaults to wrapping `generate` in a single
///   `delta` + `done` — a non-streaming backend gets the streaming
///   command "for free", just without incremental tokens.
/// - `generateJSON` defaults to the **shared schema fallback** below
///   (prompt-inject the schema, parse the model's text, validate, one
///   repair retry). A backend whose runtime can constrain decoding to a
///   schema (Foundation Models guided generation, llama.cpp GBNF, ONNX
///   GenAI) overrides it so the guarantee is enforced at decode time.
/// - `ensureModel` defaults to throwing `.unsupportedPlatform`. It is
///   **reserved** for the downloadable-Gemma tier (capacity gating,
///   resumable download, checksum pinning) and unimplemented until that
///   tier lands; the command exists now so the JS contract is stable.
public protocol AIBackend: Sendable {
    /// Capability probe — cheap, called at startup by `ai.info`. Reports
    /// whether on-device inference is usable right now and what the page
    /// can rely on (streaming, schema-constrained output). `async` because
    /// a real probe may check OS-version availability or model presence.
    func info() async -> AICapabilities

    /// One-shot text generation. The primitive every other surface is
    /// built on. Throws `AIError` (mapped to a stable `E_AI_*` bridge
    /// code) when generation is unavailable or fails.
    func generate(_ request: AIGenerateRequest) async throws -> AIGenerateResult

    /// Streaming text generation — each yield is one `AIChunk` (`delta`
    /// tokens, then a terminal `done`). Has a default implementation; a
    /// backend with true incremental decoding overrides it.
    func generateStream(_ request: AIGenerateRequest) -> AsyncThrowingStream<AIChunk, any Error>

    /// Schema-constrained structured generation. Returns JSON validated
    /// against `request.schema`. Has a default (the shared fallback); a
    /// backend with native guided generation overrides it.
    func generateJSON(_ request: AIGenerateJSONRequest) async throws -> JSONValue

    /// Ensure a downloadable model is present, streaming download
    /// progress. **Reserved** for the Gemma fallback tier — defaults to
    /// throwing `.unsupportedPlatform`.
    func ensureModel(_ request: AIEnsureModelRequest) -> AsyncThrowingStream<AIDownloadEvent, any Error>

    /// Generate one or more images from a text prompt (text→image, e.g.
    /// Stable Diffusion / Image Playground). Has a default that throws
    /// `.unsupportedPlatform`; a backend that generates images overrides it
    /// and reports `imageGeneration: true`.
    func generateImage(_ request: AIGenerateImageRequest) async throws -> AIGenerateImageResult

    /// Streaming image generation — `progress` events (denoising step,
    /// optional intermediate preview), then a terminal `done` carrying the
    /// final images. Has a default that wraps `generateImage` in a single
    /// `done`; a backend that can report per-step progress overrides it.
    func generateImageStream(_ request: AIGenerateImageRequest) -> AsyncThrowingStream<AIImageEvent, any Error>
}

public extension AIBackend {
    /// Default streaming: run the unary `generate` and surface its result
    /// as a single `delta` followed by `done`. A backend that can stream
    /// tokens incrementally overrides this; callers see the same frame
    /// shape either way.
    func generateStream(_ request: AIGenerateRequest) -> AsyncThrowingStream<AIChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await generate(request)
                    if !result.text.isEmpty { continuation.yield(.delta(result.text)) }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Default structured generation: the **shared schema fallback** used
    /// by any backend that can't constrain decoding natively. Asks the
    /// model (via plain `generate`) to emit only JSON matching the schema,
    /// parses the reply (tolerating markdown fences / surrounding prose),
    /// validates it shallowly (an object schema's `required` keys must be
    /// present), and on failure makes **one** repair attempt before giving
    /// up with `.invalidStructuredOutput`. Lives here, not per-backend, so
    /// every backend inherits the `ai.generateJSON` guarantee.
    func generateJSON(_ request: AIGenerateJSONRequest) async throws -> JSONValue {
        try await AIStructuredFallback.run(request, generate: generate)
    }

    /// Default model download: unimplemented. Reserved for the Gemma tier.
    func ensureModel(_: AIEnsureModelRequest) -> AsyncThrowingStream<AIDownloadEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: AIError.unsupportedPlatform("this backend does not support downloadable models")
            )
        }
    }

    /// Default image generation: unsupported. A text-only backend inherits
    /// this; an image backend overrides it.
    func generateImage(_: AIGenerateImageRequest) async throws -> AIGenerateImageResult {
        throw AIError.unsupportedPlatform("this backend does not generate images")
    }

    /// Default streaming image generation: run `generateImage` and surface
    /// its result as a single `done` (no per-step progress). A backend that
    /// can report denoising steps overrides this.
    func generateImageStream(_ request: AIGenerateImageRequest) -> AsyncThrowingStream<AIImageEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await generateImage(request)
                    continuation.yield(.done(images: result.images, backend: result.backend))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Capabilities

/// What `ai.info` reports. The page calls this once at startup and routes
/// on `available`; everything else is advisory detail for provenance and
/// feature-gating (e.g. don't request streaming UI when `streaming` is
/// false).
public struct AICapabilities: Sendable, Codable, Equatable {
    /// Whether on-device inference is usable right now. When `false` the
    /// app falls back to its own (e.g. cloud) tier.
    public let available: Bool
    /// Which backend answered — one of `AIBackendID`. `"none"` when no
    /// usable backend is installed.
    public let backend: String
    /// Human-facing model identifier, when known (`"system"` for a
    /// platform built-in, a Gemma variant id for the fallback tier).
    public let model: String?
    /// Whether `ai.generateStream` yields incremental tokens (vs one
    /// `delta` from the unary fallback).
    public let streaming: Bool
    /// Whether `ai.generateJSON` is enforced by schema-constrained
    /// decoding (vs the prompt-and-validate fallback).
    public let structuredOutput: Bool
    /// Whether the backend accepts image input (multimodal vision) — i.e.
    /// `images` on `ai.generate` / `ai.generateJSON` / `ai.generateStream`
    /// is honored rather than ignored.
    public let vision: Bool
    /// Whether the backend supports text→image generation
    /// (`ai.generateImage` / `ai.generateImageStream`).
    public let imageGeneration: Bool

    public init(
        available: Bool,
        backend: String,
        model: String? = nil,
        streaming: Bool = false,
        structuredOutput: Bool = false,
        vision: Bool = false,
        imageGeneration: Bool = false
    ) {
        self.available = available
        self.backend = backend
        self.model = model
        self.streaming = streaming
        self.structuredOutput = structuredOutput
        self.vision = vision
        self.imageGeneration = imageGeneration
    }

    /// The capabilities of a host with no usable backend.
    public static let none = AICapabilities(available: false, backend: AIBackendID.none)
}

/// Stable `backend` identifiers reported by `ai.info`. String constants
/// (not an enum) so a new backend can report its id without a Core change
/// and old clients still round-trip it.
public enum AIBackendID {
    public static let none = "none"
    public static let appleFoundationModels = "apple-foundation-models"
    public static let geminiNano = "gemini-nano"
    public static let phiSilica = "phi-silica"
    public static let gemmaMLX = "gemma-mlx"
    public static let gemmaMediaPipe = "gemma-mediapipe"
    public static let gemmaONNX = "gemma-onnx"
    public static let gemmaLlamaCpp = "gemma-llamacpp"

    // Image-generation (text→image) backends.
    public static let appleImagePlayground = "apple-image-playground"
    public static let stableDiffusionMLX = "stable-diffusion-mlx"
    public static let stableDiffusionONNX = "stable-diffusion-onnx"
    public static let stableDiffusionMediaPipe = "stable-diffusion-mediapipe"
}

// MARK: - Requests / results

/// A text-generation request (`ai.generate` / `ai.generateStream`).
/// Multimodal: attach `images` for a vision-capable backend (one reporting
/// `vision: true`) — e.g. "describe this", OCR, visual Q&A.
public struct AIGenerateRequest: Sendable, Codable, Equatable {
    /// Optional system / instruction prompt.
    public var system: String?
    /// The user prompt. Required.
    public var prompt: String
    /// Optional image inputs for a vision-capable backend. Ignored by a
    /// backend that reports `vision: false`.
    public var images: [AIImage]?
    /// Soft cap on generated tokens; `nil` lets the backend choose.
    public var maxTokens: Int?
    /// Sampling temperature; `nil` lets the backend choose.
    public var temperature: Double?

    public init(
        system: String? = nil,
        prompt: String,
        images: [AIImage]? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil
    ) {
        self.system = system
        self.prompt = prompt
        self.images = images
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

/// An image supplied as input to a multimodal request. Carry it inline as
/// base64 (small / canvas captures) **or** as a filesystem `path` the
/// backend reads directly — the bridge-efficient route for large on-disk
/// images, so the bytes never cross the JS↔Swift bridge as a ~1.33×
/// base64 string (the same reasoning behind `fs.extractZip`'s path-to-path
/// design). Provide exactly one of `dataBase64` / `path`.
public struct AIImage: Sendable, Codable, Equatable {
    /// Base64-encoded image bytes, for inline (small) images.
    public var dataBase64: String?
    /// Filesystem path the backend reads directly, for large on-disk
    /// images (avoids a base64 round-trip across the bridge).
    public var path: String?
    /// MIME type hint (e.g. `"image/png"`, `"image/jpeg"`); optional —
    /// backends may sniff it.
    public var mimeType: String?

    public init(dataBase64: String? = nil, path: String? = nil, mimeType: String? = nil) {
        self.dataBase64 = dataBase64
        self.path = path
        self.mimeType = mimeType
    }

    /// An inline base64 image.
    public static func inline(_ dataBase64: String, mimeType: String? = nil) -> AIImage {
        AIImage(dataBase64: dataBase64, mimeType: mimeType)
    }

    /// An on-disk image the backend reads directly.
    public static func file(_ path: String, mimeType: String? = nil) -> AIImage {
        AIImage(path: path, mimeType: mimeType)
    }
}

/// A structured-generation request (`ai.generateJSON`). `schema` is a JSON
/// Schema object the result must satisfy; backends that can constrain
/// decoding use it directly, the fallback injects it into the prompt and
/// validates against it.
public struct AIGenerateJSONRequest: Sendable, Codable, Equatable {
    public var system: String?
    public var prompt: String
    public var schema: JSONValue
    /// Optional image inputs for a vision-capable backend — e.g. extract
    /// typed fields from a photo. Ignored when `vision: false`.
    public var images: [AIImage]?
    public var maxTokens: Int?
    public var temperature: Double?

    public init(
        system: String? = nil,
        prompt: String,
        schema: JSONValue,
        images: [AIImage]? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil
    ) {
        self.system = system
        self.prompt = prompt
        self.schema = schema
        self.images = images
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

/// Result of a unary `ai.generate`.
public struct AIGenerateResult: Sendable, Codable, Equatable {
    /// The generated text.
    public let text: String
    /// Which backend produced it (one of `AIBackendID`) — lets the page
    /// show provenance / make routing decisions.
    public let backend: String

    public init(text: String, backend: String) {
        self.text = text
        self.backend = backend
    }
}

/// One frame of a streaming generation. Tagged the same way as
/// `FsExtractEvent`: a run of `delta` chunks carrying token text, then a
/// terminal `done`.
public struct AIChunk: Sendable, Codable, Equatable {
    /// `"delta"` (incremental text in `text`) or `"done"` (stream end).
    public let type: String
    /// The incremental text for a `delta`; `nil` on `done`.
    public let text: String?

    public init(type: String, text: String?) {
        self.type = type
        self.text = text
    }

    /// An incremental token chunk.
    public static func delta(_ text: String) -> AIChunk { AIChunk(type: "delta", text: text) }
    /// The terminal end-of-stream chunk.
    public static let done = AIChunk(type: "done", text: nil)
}

// MARK: - Image generation (text→image)

/// A text→image generation request (`ai.generateImage` /
/// `ai.generateImageStream`). All knobs are optional with backend-chosen
/// defaults so a bare `{ prompt }` works.
public struct AIGenerateImageRequest: Sendable, Codable, Equatable {
    /// The image prompt. Required.
    public var prompt: String
    /// Optional negative prompt (what to avoid), for backends that accept one.
    public var negativePrompt: String?
    public var width: Int?
    public var height: Int?
    /// Denoising / sampling steps; `nil` lets the backend choose.
    public var steps: Int?
    /// RNG seed for reproducibility; `nil` is random. The seed actually
    /// used is echoed back per image in `AIGeneratedImage.seed`.
    public var seed: Int?
    /// How many images to generate; `nil` means one.
    public var count: Int?
    /// Where to write the generated images. When set, the result returns
    /// file `path`s (bridge-efficient — multi-MB image bytes never cross
    /// as base64); when `nil`, the result returns base64 bytes inline.
    /// Mirrors `fs`'s path-to-path stance for large binary payloads.
    public var outputDirectory: String?

    public init(
        prompt: String,
        negativePrompt: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        steps: Int? = nil,
        seed: Int? = nil,
        count: Int? = nil,
        outputDirectory: String? = nil
    ) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.steps = steps
        self.seed = seed
        self.count = count
        self.outputDirectory = outputDirectory
    }
}

/// One generated image. Carries inline base64 bytes **or** a written file
/// `path` (which of the two depends on whether the request supplied an
/// `outputDirectory`).
public struct AIGeneratedImage: Sendable, Codable, Equatable {
    /// Base64-encoded image bytes, when the request had no `outputDirectory`.
    public var dataBase64: String?
    /// Path to the written image, when the request supplied an `outputDirectory`.
    public var path: String?
    /// MIME type of the image (e.g. `"image/png"`).
    public var mimeType: String?
    /// The seed actually used, for reproducibility.
    public var seed: Int?

    public init(dataBase64: String? = nil, path: String? = nil, mimeType: String? = nil, seed: Int? = nil) {
        self.dataBase64 = dataBase64
        self.path = path
        self.mimeType = mimeType
        self.seed = seed
    }
}

/// Result of a unary `ai.generateImage`.
public struct AIGenerateImageResult: Sendable, Codable, Equatable {
    public var images: [AIGeneratedImage]
    /// Which backend produced them (one of `AIBackendID`) — image
    /// generation may use a different underlying model than text.
    public var backend: String

    public init(images: [AIGeneratedImage], backend: String) {
        self.images = images
        self.backend = backend
    }
}

/// One frame of a streaming image generation. Tagged like the other
/// streaming events: `progress` (a denoising step, with an optional
/// intermediate `preview`), then a terminal `done` carrying the final
/// `images`.
public struct AIImageEvent: Sendable, Codable, Equatable {
    /// `"progress"` or `"done"`.
    public let type: String
    /// Current step (on `progress`).
    public let step: Int?
    /// Total steps, when known (on `progress`).
    public let totalSteps: Int?
    /// An optional intermediate preview image (on `progress`), for
    /// backends that surface partially-denoised frames.
    public let preview: AIGeneratedImage?
    /// The final images (on `done`).
    public let images: [AIGeneratedImage]?
    /// The producing backend (on `done`).
    public let backend: String?

    public init(
        type: String,
        step: Int? = nil,
        totalSteps: Int? = nil,
        preview: AIGeneratedImage? = nil,
        images: [AIGeneratedImage]? = nil,
        backend: String? = nil
    ) {
        self.type = type
        self.step = step
        self.totalSteps = totalSteps
        self.preview = preview
        self.images = images
        self.backend = backend
    }

    public static func progress(step: Int, totalSteps: Int?, preview: AIGeneratedImage? = nil) -> AIImageEvent {
        AIImageEvent(type: "progress", step: step, totalSteps: totalSteps, preview: preview)
    }

    public static func done(images: [AIGeneratedImage], backend: String) -> AIImageEvent {
        AIImageEvent(type: "done", images: images, backend: backend)
    }
}

// MARK: - Model download (reserved)

/// A request to ensure a downloadable model is present. **Reserved** for
/// the Gemma fallback tier.
public struct AIEnsureModelRequest: Sendable, Codable, Equatable {
    /// Backend-specific model identifier; `nil` means the backend's
    /// default model.
    public var model: String?

    public init(model: String? = nil) {
        self.model = model
    }
}

/// One frame of a model download. **Reserved** for the Gemma fallback
/// tier. Mirrors the `progress` / `done` shape of `FsExtractEvent`.
public struct AIDownloadEvent: Sendable, Codable, Equatable {
    /// `"progress"` or `"done"`.
    public let type: String
    public let bytesDone: Int64?
    public let totalBytes: Int64?

    public init(type: String, bytesDone: Int64? = nil, totalBytes: Int64? = nil) {
        self.type = type
        self.bytesDone = bytesDone
        self.totalBytes = totalBytes
    }

    public static func progress(bytesDone: Int64, totalBytes: Int64?) -> AIDownloadEvent {
        AIDownloadEvent(type: "progress", bytesDone: bytesDone, totalBytes: totalBytes)
    }

    public static let done = AIDownloadEvent(type: "done")
}

// MARK: - Errors

/// Failures an `AIBackend` surfaces. Each maps to a stable `E_AI_*`
/// `BridgeError` code (see `bridgeError`) so JS can switch on the cause.
public enum AIError: Error, Equatable {
    /// No usable backend / on-device inference is unavailable. The page
    /// should fall back to its own tier. (`ai.info` reports this ahead of
    /// time; this is the error if a caller invokes anyway.)
    case unavailable(String)
    /// The backend was available but generation failed.
    case generationFailed(String)
    /// `ai.generateJSON` could not obtain schema-valid JSON (even after a
    /// repair attempt, on the fallback path).
    case invalidStructuredOutput(String)
    /// The operation isn't supported on this backend/platform (e.g.
    /// `ai.ensureModel` before the downloadable tier ships).
    case unsupportedPlatform(String)

    /// Stable bridge code for this error.
    public var code: String {
        switch self {
        case .unavailable: AIError.unavailableCode
        case .generationFailed: AIError.generationCode
        case .invalidStructuredOutput: AIError.structuredOutputCode
        case .unsupportedPlatform: BridgeError.unimplemented
        }
    }

    /// The `BridgeError` this maps to at the JS boundary.
    public var bridgeError: BridgeError {
        switch self {
        case let .unavailable(m), let .generationFailed(m),
             let .invalidStructuredOutput(m), let .unsupportedPlatform(m):
            BridgeError(code: code, message: m)
        }
    }

    public static let unavailableCode = "E_AI_UNAVAILABLE"
    public static let generationCode = "E_AI_GENERATION"
    public static let structuredOutputCode = "E_AI_STRUCTURED_OUTPUT"
}

// MARK: - None backend

/// The backend installed when an app uses `AIPlugin` without supplying a
/// real one. Reports `available:false` so the page falls back to its own
/// tier, and rejects generation with `.unavailable`. Lets an app wire the
/// `ai.*` JS contract today and swap in a real backend later without a
/// page change.
public struct NoneBackend: AIBackend {
    public init() {}

    public func info() async -> AICapabilities { .none }

    public func generate(_: AIGenerateRequest) async throws -> AIGenerateResult {
        throw AIError.unavailable("no on-device AI backend is installed")
    }

    public func generateImage(_: AIGenerateImageRequest) async throws -> AIGenerateImageResult {
        throw AIError.unavailable("no on-device AI backend is installed")
    }
}
