import Foundation

/// Optional plugin exposing the `ai.*` command set — on-device (or
/// otherwise native) LLM inference behind the bridge, so the web layer
/// stays provider-agnostic. Not auto-installed: an app opts in, and
/// supplies the backend.
///
/// ```swift
/// runtime.run { ctx in
///     ctx.use(AIPlugin(MyBackend()))   // a real backend, or…
///     ctx.use(AIPlugin())              // NoneBackend — contract wired, available:false
/// }
/// ```
///
/// The page probes `ai.info` once and routes on `available`; with no real
/// backend it reads `available:false` and the app falls back to its own
/// (e.g. cloud) tier — so wiring `AIPlugin()` today and swapping in a real
/// backend later needs no page change.
///
/// JS surface (all via the standard `invoke` / `subscribe`):
/// - `ai.info` → `AICapabilities`
/// - `ai.generate` → `AIGenerateResult`
/// - `ai.generateJSON` → schema-valid JSON (any shape)
/// - `ai.generateStream` (subscribe) → `AIChunk` (`delta`…, then `done`)
/// - `ai.ensureModel` (subscribe) → `AIDownloadEvent` — **reserved** for
///   the downloadable-Gemma tier; throws `E_UNIMPLEMENTED` until then.
public struct AIPlugin: Plugin {
    public static let pluginName = "ai"

    private let backend: any AIBackend

    /// Install with a real backend.
    public init(_ backend: any AIBackend) {
        self.backend = backend
    }

    /// Install with `NoneBackend` — the `ai.*` contract is registered but
    /// reports `available:false`. Lets an app wire the page's AI tier now
    /// and drop in a backend later.
    public init() {
        backend = NoneBackend()
    }

    public func register(into registry: CommandRegistry, app _: any AppContext) {
        let backend = backend

        registry.register("ai.info", typed: { (_: EmptyArgs, _) async -> AICapabilities in
            await backend.info()
        })

        registry.register("ai.generate", typed: { (req: AIGenerateRequest, _) async throws -> AIGenerateResult in
            try await Self.mapping { try await backend.generate(req) }
        })

        registry.register("ai.generateJSON", typed: { (req: AIGenerateJSONRequest, _) async throws -> JSONValue in
            try await Self.mapping { try await backend.generateJSON(req) }
        })

        // Streaming text: `delta` events, then a terminal `done`, then the
        // bridge's `end` frame (same path `fs.extractZipProgress` uses).
        registry.registerStream(
            "ai.generateStream",
            typed: { (req: AIGenerateRequest, _) -> AsyncThrowingStream<AIChunk, any Error> in
                Self.mapping(backend.generateStream(req))
            }
        )

        // Reserved: downloadable-model management for the Gemma tier.
        // Present so the JS contract is stable; the default backend impl
        // throws `unsupportedPlatform` (→ `E_UNIMPLEMENTED`).
        registry.registerStream(
            "ai.ensureModel",
            typed: { (req: AIEnsureModelRequest, _) -> AsyncThrowingStream<AIDownloadEvent, any Error> in
                Self.mapping(backend.ensureModel(req))
            }
        )

        // Text→image generation. Default backend impl throws
        // `unsupportedPlatform` until an image backend is injected.
        registry.register(
            "ai.generateImage",
            typed: { (req: AIGenerateImageRequest, _) async throws -> AIGenerateImageResult in
                try await Self.mapping { try await backend.generateImage(req) }
            }
        )

        // Streaming image generation: `progress` (step / optional preview),
        // then a terminal `done` carrying the final images.
        registry.registerStream(
            "ai.generateImageStream",
            typed: { (req: AIGenerateImageRequest, _) -> AsyncThrowingStream<AIImageEvent, any Error> in
                Self.mapping(backend.generateImageStream(req))
            }
        )
    }

    // MARK: - AIError → BridgeError mapping

    /// Run a unary backend call, converting a thrown `AIError` into its
    /// stable `E_AI_*` `BridgeError` so JS sees a switchable code rather
    /// than a generic `E_HANDLER`.
    private static func mapping<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as AIError {
            throw error.bridgeError
        }
    }

    /// Re-emit a backend stream, converting a terminal `AIError` into its
    /// stable `BridgeError` (the unary mapping's streaming counterpart).
    private static func mapping<Chunk: Sendable>(
        _ upstream: AsyncThrowingStream<Chunk, any Error>
    ) -> AsyncThrowingStream<Chunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in upstream { continuation.yield(chunk) }
                    continuation.finish()
                } catch let error as AIError {
                    continuation.finish(throwing: error.bridgeError)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
