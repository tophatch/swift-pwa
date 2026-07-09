import Foundation

/// Optional plugin exposing the `ai.vision.*` command set — promptable
/// on-device image segmentation (SAM-family) behind the bridge. A separate
/// plugin from `AIPlugin` (see `SegmentationBackend`'s doc comment for why),
/// sharing its `ai.*` namespace and reusing its `AIImage` /
/// `AIEnsureModelRequest` / `AIDownloadEvent` types and `BridgeError`
/// conventions. Not auto-installed: an app opts in, and supplies the
/// backend.
///
/// ```swift
/// runtime.run { ctx in
///     ctx.use(VisionPlugin(MobileSAMBackend(...)))   // a real backend, or…
///     ctx.use(VisionPlugin())                        // NoneBackend — contract wired, available:false
/// }
/// ```
///
/// The page probes `ai.vision.info` once and routes on `available`; with no
/// real backend it reads `available:false` and hides its ML object-select
/// affordance.
///
/// JS surface (all via the standard `invoke` / `subscribe`):
/// - `ai.vision.info` → `VisionCapabilities`
/// - `ai.vision.openSession` → `VisionSession` (runs the encoder)
/// - `ai.vision.segment` → `SegmentResult` (runs the decoder)
/// - `ai.vision.closeSession` → `EmptyResult`
/// - `ai.vision.segmentAll` → `SegmentResult` — **reserved**; throws
///   `E_UNIMPLEMENTED` until an AMG-capable backend is injected.
/// - `ai.vision.segmentAllStream` (subscribe) → `VisionProgress`
///   (`progress`…, then `done`) — **reserved**, same as above.
/// - `ai.vision.ensureModel` (subscribe) → `AIDownloadEvent` — **reserved**
///   for the downloadable-model tier.
/// - `ai.vision.benchmark` → `VisionBenchmark` — **reserved**, low-priority.
public struct VisionPlugin: Plugin {
    public static let pluginName = "vision"

    private let backend: any SegmentationBackend

    /// Install with a real backend.
    public init(_ backend: any SegmentationBackend) {
        self.backend = backend
    }

    /// Install with `NoneSegmentationBackend` — the `ai.vision.*` contract
    /// is registered but reports `available:false`.
    public init() {
        backend = NoneSegmentationBackend()
    }

    public func register(into registry: CommandRegistry, app _: any AppContext) {
        let backend = backend

        registry.register("ai.vision.info", typed: { (_: EmptyArgs, _) async -> VisionCapabilities in
            await backend.info()
        })

        registry.register(
            "ai.vision.openSession",
            typed: { (req: OpenSessionRequest, _) async throws -> VisionSession in
                try await Self.mapping { try await backend.openSession(req) }
            }
        )

        registry.register("ai.vision.segment", typed: { (req: SegmentRequest, _) async throws -> SegmentResult in
            try await Self.mapping { try await backend.segment(req) }
        })

        registry.register(
            "ai.vision.closeSession",
            typed: { (req: CloseSessionRequest, _) async -> EmptyResult in
                await backend.closeSession(req.sessionID)
                return EmptyResult()
            }
        )

        // Reserved: automatic mask generation. Present so the JS contract
        // is stable; the default backend impl throws `unsupportedPlatform`
        // (→ `E_UNIMPLEMENTED`).
        registry.register(
            "ai.vision.segmentAll",
            typed: { (req: SegmentAllRequest, _) async throws -> SegmentResult in
                try await Self.mapping { try await backend.segmentAll(req) }
            }
        )

        registry.registerStream(
            "ai.vision.segmentAllStream",
            typed: { (req: SegmentAllRequest, _) -> AsyncThrowingStream<VisionProgress, any Error> in
                Self.mapping(backend.segmentAllStream(req))
            }
        )

        // Reserved: downloadable-model management. Default backend impl
        // throws `unsupportedPlatform` until a downloadable-model tier ships.
        registry.registerStream(
            "ai.vision.ensureModel",
            typed: { (req: AIEnsureModelRequest, _) -> AsyncThrowingStream<AIDownloadEvent, any Error> in
                Self.mapping(backend.ensureModel(req))
            }
        )

        // Reserved: device-capability benchmark. Default backend impl
        // throws `unsupportedPlatform`.
        registry.register("ai.vision.benchmark", typed: { (_: EmptyArgs, _) async throws -> VisionBenchmark in
            try await Self.mapping { try await backend.benchmark() }
        })
    }

    // MARK: - VisionError → BridgeError mapping

    /// Run a unary backend call, converting a thrown `VisionError` into its
    /// stable `E_VISION_*` `BridgeError` so JS sees a switchable code rather
    /// than a generic `E_HANDLER`.
    private static func mapping<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as VisionError {
            throw error.bridgeError
        }
    }

    /// Re-emit a backend stream, converting a terminal `VisionError` into
    /// its stable `BridgeError` (the unary mapping's streaming counterpart).
    private static func mapping<Chunk: Sendable>(
        _ upstream: AsyncThrowingStream<Chunk, any Error>
    ) -> AsyncThrowingStream<Chunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in upstream { continuation.yield(chunk) }
                    continuation.finish()
                } catch let error as VisionError {
                    continuation.finish(throwing: error.bridgeError)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Request to `ai.vision.closeSession`.
public struct CloseSessionRequest: Sendable, Codable, Equatable {
    public var sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
    }
}
