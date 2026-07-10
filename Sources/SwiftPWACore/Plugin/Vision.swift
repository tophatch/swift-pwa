import Foundation

/// A promptable on-device image-segmentation backend (SAM-family), backing
/// the `ai.vision.*` command set. Defined in Core (dependency-free) so
/// `VisionPlugin` can offer the contract without `SwiftPWACore` taking on a
/// model-runtime dependency — concrete implementations (e.g. an ONNX
/// Runtime MobileSAM backend) live in an optional target and are injected
/// by apps, exactly like `AIBackend`.
///
/// This is a **separate** protocol/plugin from `AIBackend`/`AIPlugin`,
/// deliberately: `AIBackend` is generate-only (request → response/stream),
/// while segmentation is discriminative (image + spatial prompt → masks)
/// and needs a **session** primitive — SAM's encoder is the expensive step
/// (an image → a cached embedding) and the decoder is cheap (embedding +
/// prompt → mask, run many times per encode). See
/// `docs/proposals/segmentation-plugin.md` for the full design rationale.
///
/// Only `info()`, `openSession(_:)`, `segment(_:)`, and `closeSession(_:)`
/// are required. `segmentAll`/`segmentAllStream`/`ensureModel`/`benchmark`
/// have default implementations so a backend that does the bare minimum
/// (and every test double) still compiles — mirroring `AIBackend`'s
/// required-core / default-extras split.
public protocol SegmentationBackend: Sendable {
    /// Capability probe — cheap, called at startup by `ai.vision.info`.
    func info() async -> VisionCapabilities

    /// Run the (expensive) image encoder and cache the resulting embedding
    /// native-side under an opaque session id. Callers re-use the session
    /// across many `segment` calls against the same image.
    func openSession(_ request: OpenSessionRequest) async throws -> VisionSession

    /// Run the (cheap) prompt decoder against a session's cached embedding.
    func segment(_ request: SegmentRequest) async throws -> SegmentResult

    /// Release a session's cached embedding. Idempotent — closing an
    /// unknown/already-closed session is a no-op, not an error.
    func closeSession(_ sessionID: String) async

    /// Automatic mask generation — a grid-of-prompts sweep + NMS returning
    /// every distinct object as its own mask. Default throws
    /// `.unsupportedPlatform`: a backend that only does prompted
    /// segmentation is valid, and the consumer falls back to tap-to-segment.
    func segmentAll(_ request: SegmentAllRequest) async throws -> SegmentResult

    /// Streaming automatic mask generation — `progress` events, then a
    /// terminal `done` carrying the final masks. Default wraps
    /// `segmentAll` in a single `done`.
    func segmentAllStream(_ request: SegmentAllRequest) -> AsyncThrowingStream<VisionProgress, any Error>

    /// Ensure a downloadable model is present, streaming download
    /// progress. Reuses Core's `AIEnsureModelRequest`/`AIDownloadEvent` —
    /// the download machinery (resumable, checksum-pinned) is
    /// modality-agnostic. Default throws `.unsupportedPlatform` (bundled-
    /// model backends).
    func ensureModel(_ request: AIEnsureModelRequest) -> AsyncThrowingStream<AIDownloadEvent, any Error>

    /// Timed synthetic encode + decode, for the consumer to gate an eager
    /// "pre-segment everything" UX vs. lean tap-to-segment. Default runs
    /// one real `openSession`/`segment`/`closeSession` against a small
    /// synthetic image.
    func benchmark() async throws -> VisionBenchmark
}

public extension SegmentationBackend {
    func segmentAll(_: SegmentAllRequest) async throws -> SegmentResult {
        throw VisionError.unsupportedPlatform("this backend does not support automatic mask generation")
    }

    func segmentAllStream(_ request: SegmentAllRequest) -> AsyncThrowingStream<VisionProgress, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await segmentAll(request)
                    continuation.yield(.done(masks: result.masks))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func ensureModel(_: AIEnsureModelRequest) -> AsyncThrowingStream<AIDownloadEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: VisionError.unsupportedPlatform("this backend does not support downloadable models")
            )
        }
    }

    func benchmark() async throws -> VisionBenchmark {
        throw VisionError.unsupportedPlatform("this backend does not support benchmarking")
    }
}

// MARK: - Capabilities

/// What `ai.vision.info` reports. The page calls this once at startup and
/// routes on `available`.
public struct VisionCapabilities: Sendable, Codable, Equatable {
    /// Whether on-device segmentation is usable here.
    public let available: Bool
    /// Which backend answered — one of `VisionBackendID`. `"none"` when no
    /// usable backend is installed.
    public let backend: String
    /// Human-facing model identifier, when known.
    public let model: String?
    /// Whether `ai.vision.segment` accepts point prompts.
    public let pointPrompts: Bool
    /// Whether `ai.vision.segment` accepts a box prompt.
    public let boxPrompts: Bool
    /// Whether `multimask: true` returns multiple ranked candidates.
    public let multimask: Bool
    /// Whether `ai.vision.segmentAll` (automatic mask generation) is supported.
    public let autoMask: Bool
    /// Largest source-image dimension (pixels, longest side) the backend
    /// will encode; `nil` when the backend imposes no fixed cap.
    public let maxImageSize: Int?
    /// Whether an opened session's embedding is cached for repeat
    /// `segment` calls (vs. re-encoding every call).
    public let sessionCaching: Bool
    /// The execution provider the backend is running on, once known —
    /// `"cpu"`, `"cuda"` (Linux GPU build on NVIDIA), or `"directml"` (Windows
    /// GPU build on any DX12 GPU). `nil` until a session has been created
    /// (the provider is only decided at `CreateSession`), and on backends that
    /// don't model it (the OS picks on Apple/Android). See the `ai.onnx_gpu`
    /// desktop GPU tier.
    public let provider: String?

    public init(
        available: Bool,
        backend: String,
        model: String? = nil,
        pointPrompts: Bool = false,
        boxPrompts: Bool = false,
        multimask: Bool = false,
        autoMask: Bool = false,
        maxImageSize: Int? = nil,
        sessionCaching: Bool = false,
        provider: String? = nil
    ) {
        self.available = available
        self.backend = backend
        self.model = model
        self.pointPrompts = pointPrompts
        self.boxPrompts = boxPrompts
        self.multimask = multimask
        self.autoMask = autoMask
        self.maxImageSize = maxImageSize
        self.sessionCaching = sessionCaching
        self.provider = provider
    }

    /// The capabilities of a host with no usable backend.
    public static let none = VisionCapabilities(available: false, backend: VisionBackendID.none)
}

/// Stable `backend` identifiers reported by `ai.vision.info`. String
/// constants (not an enum) so a new backend can report its id without a
/// Core change and old clients still round-trip it.
public enum VisionBackendID {
    public static let none = "none"
    public static let mobileSAMONNX = "mobile-sam-onnx"
}

// MARK: - Session: open (encode)

/// Request to `ai.vision.openSession` — runs the image encoder.
public struct OpenSessionRequest: Sendable, Codable, Equatable {
    /// The source image. Exactly one of `AIImage.path`/`dataBase64` — prefer
    /// `path` for doc-sized layers so the bytes don't cross the bridge as a
    /// base64 string on every re-encode.
    public var image: AIImage

    public init(image: AIImage) {
        self.image = image
    }
}

/// Result of `ai.vision.openSession`. `width`/`height` echo the source
/// pixel dimensions so the consumer can map prompt coordinates 1:1.
public struct VisionSession: Sendable, Codable, Equatable {
    public var sessionID: String
    public var width: Int
    public var height: Int

    public init(sessionID: String, width: Int, height: Int) {
        self.sessionID = sessionID
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case width
        case height
    }
}

// MARK: - Segment (decode)

/// A point prompt in source-image pixel coordinates. `label` is `1` for a
/// foreground (include) point, `0` for background (exclude).
public struct VisionPoint: Sendable, Codable, Equatable {
    public var x: Double
    public var y: Double
    public var label: Int

    public init(x: Double, y: Double, label: Int) {
        self.x = x
        self.y = y
        self.label = label
    }
}

/// Request to `ai.vision.segment` — runs the (cheap) prompt decoder against
/// a previously opened session's cached embedding. At least one of
/// `points`/`box` should be supplied.
public struct SegmentRequest: Sendable, Codable, Equatable {
    public var sessionID: String
    /// Positive + negative point prompts, in source-image pixels.
    public var points: [VisionPoint]?
    /// An optional box prompt `[x0, y0, x1, y1]`, in source-image pixels.
    public var box: [Double]?
    /// Return the model's ranked mask candidates (vs. just the best one).
    public var multimask: Bool

    public init(sessionID: String, points: [VisionPoint]? = nil, box: [Double]? = nil, multimask: Bool = false) {
        self.sessionID = sessionID
        self.points = points
        self.box = box
        self.multimask = multimask
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case points
        case box
        case multimask
    }

    /// Custom decoding: `multimask` is non-optional but should default to
    /// `false` when the caller omits it — the synthesized `Decodable` would
    /// otherwise require the key present, which every hand-written test/JS
    /// payload that only sends `points`/`box` would fail against E_DECODE.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        points = try container.decodeIfPresent([VisionPoint].self, forKey: .points)
        box = try container.decodeIfPresent([Double].self, forKey: .box)
        multimask = try container.decodeIfPresent(Bool.self, forKey: .multimask) ?? false
    }
}

/// One segmentation mask. `bounds` is the tight bbox in source pixels
/// (lets the consumer allocate/scan only the touched region); `rle` is a
/// row-major run-length encoding over the `bounds` box (integer run
/// lengths, first run = count of background pixels) — compact for the
/// many-masks automatic-mask-generation case and for the large sparse
/// masks typical of an object on an empty canvas.
public struct VisionMask: Sendable, Codable, Equatable {
    /// Tight bounding box `[x0, y0, x1, y1]` in source pixels.
    public var bounds: [Int]
    /// Row-major run-length encoding over `bounds`, background-first.
    public var rle: [Int]
    /// Model IoU/quality estimate, for ranking and `multimask` disambiguation.
    public var score: Double

    public init(bounds: [Int], rle: [Int], score: Double) {
        self.bounds = bounds
        self.rle = rle
        self.score = score
    }
}

/// Result of a unary `ai.vision.segment` / `ai.vision.segmentAll`. Masks
/// are best-first when ranked (`multimask`/AMG).
public struct SegmentResult: Sendable, Codable, Equatable {
    public var masks: [VisionMask]

    public init(masks: [VisionMask]) {
        self.masks = masks
    }
}

// MARK: - Automatic mask generation (fast-follow; contract reserved now)

/// Request to `ai.vision.segmentAll` / `segmentAllStream` — a grid-of-
/// prompts sweep + NMS returning every distinct object as its own mask.
/// **Reserved**: no shipped backend supports this yet (see
/// `docs/proposals/segmentation-plugin.md`), but the shape is stable so it
/// lands as a fast-follow without a contract break.
public struct SegmentAllRequest: Sendable, Codable, Equatable {
    public var sessionID: String
    public var pointsPerSide: Int?
    public var iouThreshold: Double?
    public var minAreaPx: Int?

    public init(sessionID: String, pointsPerSide: Int? = nil, iouThreshold: Double? = nil, minAreaPx: Int? = nil) {
        self.sessionID = sessionID
        self.pointsPerSide = pointsPerSide
        self.iouThreshold = iouThreshold
        self.minAreaPx = minAreaPx
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case pointsPerSide
        case iouThreshold
        case minAreaPx
    }
}

/// One frame of a streaming `ai.vision.segmentAllStream`. A run of
/// `progress` frames, then a terminal `done` carrying the final masks.
public struct VisionProgress: Sendable, Codable, Equatable {
    /// `"progress"` or `"done"`.
    public let type: String
    public let done: Int?
    public let total: Int?
    public let masks: [VisionMask]?

    public init(type: String, done: Int? = nil, total: Int? = nil, masks: [VisionMask]? = nil) {
        self.type = type
        self.done = done
        self.total = total
        self.masks = masks
    }

    public static func progress(done: Int, total: Int) -> VisionProgress {
        VisionProgress(type: "progress", done: done, total: total)
    }

    public static func done(masks: [VisionMask]) -> VisionProgress {
        VisionProgress(type: "done", masks: masks)
    }
}

// MARK: - Benchmark (fast-follow; contract reserved now)

/// Result of `ai.vision.benchmark` — real synthetic timing, for the
/// consumer's device-capability gate. **Reserved**; ship low-priority per
/// the maintainer evaluation (the primary device-classing path is the app
/// timing its own first real `openSession`/`segment`).
public struct VisionBenchmark: Sendable, Codable, Equatable {
    public var encodeMs: Int
    public var decodeMs: Int
    public var segmentAllMs: Int?
    /// `"high"` | `"mid"` | `"low"`.
    public var deviceClass: String

    public init(encodeMs: Int, decodeMs: Int, segmentAllMs: Int? = nil, deviceClass: String) {
        self.encodeMs = encodeMs
        self.decodeMs = decodeMs
        self.segmentAllMs = segmentAllMs
        self.deviceClass = deviceClass
    }
}

// MARK: - Errors

/// Failures a `SegmentationBackend` surfaces. Each maps to a stable
/// `E_VISION_*` `BridgeError` code so JS can switch on the cause — mirrors
/// `AIError`'s scheme.
public enum VisionError: Error, Equatable {
    /// No usable backend / on-device segmentation is unavailable.
    case unavailable(String)
    /// `sessionId` is unknown or was evicted (LRU/idle) — re-open and retry.
    case session(String)
    /// The backend was available but inference failed.
    case segmentationFailed(String)
    /// The operation isn't supported on this backend (e.g. `segmentAll`
    /// before an AMG-capable backend is injected).
    case unsupportedPlatform(String)
    /// Acquiring a downloadable model failed — network error, or the
    /// downloaded bytes didn't match the pinned checksum.
    case modelDownloadFailed(String)

    /// Stable bridge code for this error.
    public var code: String {
        switch self {
        case .unavailable: VisionError.unavailableCode
        case .session: VisionError.sessionCode
        case .segmentationFailed: VisionError.segmentationCode
        case .unsupportedPlatform: BridgeError.unimplemented
        case .modelDownloadFailed: VisionError.modelCode
        }
    }

    /// The `BridgeError` this maps to at the JS boundary.
    public var bridgeError: BridgeError {
        switch self {
        case let .unavailable(m), let .session(m), let .segmentationFailed(m),
             let .unsupportedPlatform(m), let .modelDownloadFailed(m):
            BridgeError(code: code, message: m)
        }
    }

    public static let unavailableCode = "E_VISION_UNAVAILABLE"
    public static let sessionCode = "E_VISION_SESSION"
    public static let segmentationCode = "E_VISION_SEGMENTATION"
    public static let modelCode = "E_VISION_MODEL"
}

// MARK: - None backend

/// The backend installed when an app uses `VisionPlugin` without supplying
/// a real one. Reports `available:false` so the page hides its ML object-
/// select mode; rejects session/segment calls with `.unavailable`. Lets an
/// app wire the `ai.vision.*` JS contract today and swap in a real backend
/// later without a page change.
public struct NoneSegmentationBackend: SegmentationBackend {
    public init() {}

    public func info() async -> VisionCapabilities { .none }

    public func openSession(_: OpenSessionRequest) async throws -> VisionSession {
        throw VisionError.unavailable("no on-device segmentation backend is installed")
    }

    public func segment(_: SegmentRequest) async throws -> SegmentResult {
        throw VisionError.unavailable("no on-device segmentation backend is installed")
    }

    public func closeSession(_: String) async {}
}
