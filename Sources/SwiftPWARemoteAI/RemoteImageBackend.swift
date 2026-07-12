import Foundation
import SwiftPWACore

/// The per-API seam an adopter implements to add a **remote** image generator
/// (a cloud API or a local-network appliance) to the `ai.*` surface. The
/// framework ships two conformances — ``ImagenProvider`` and ``ComfyUIProvider``
/// — and a third API is *just another conformance*: no changes to `SwiftPWACore`
/// or `MultiModelImageBackend`.
///
/// A provider owns the whole **API choreography** given an injected
/// ``NetworkClient`` — so it covers both one-shot APIs (Imagen: a single POST)
/// and async-job APIs (ComfyUI: submit → poll → fetch N) with the same protocol.
/// ``RemoteImageBackend`` wraps a provider to supply the `AIBackend` conformance
/// (info / seed / output plumbing / error mapping), so a provider writes *only*
/// the image logic.
public protocol RemoteImageProvider: Sendable {
    /// The models this provider serves, for `ai.info().models` — each with its
    /// capabilities / availability / `offlineCapable` / licence for the picker.
    /// Static (no network): availability reflects best-known cheap state (e.g. a
    /// cloud model is `.ready`; a missing key surfaces at generate time).
    var models: [AIModelInfo] { get }

    /// The backend id stamped on results for provenance (`result.backend`).
    var backendID: String { get }

    /// Run the full generate for `request` using `client`, returning the images.
    /// Owns request building, the API's request/poll/fetch flow, and response
    /// parsing — including **seed handling**, which is API-specific (Imagen's
    /// seed excludes watermarking / forces a single sample; ComfyUI randomizes a
    /// nil seed per batch item). The provider echoes the seed it actually used
    /// in each `AIGeneratedImage.seed` (or leaves it `nil` when the API doesn't
    /// expose one). Throw `AIError.generationFailed` on an API error.
    func generateImage(
        _ request: AIGenerateImageRequest,
        client: any NetworkClient
    ) async throws -> [AIGeneratedImage]

    /// Streaming generate. Defaults to running ``generateImage`` and emitting a
    /// single terminal `done` (no intermediate progress); a provider that can
    /// report progress (e.g. ComfyUI polling / websocket) overrides it.
    func generateImageStream(
        _ request: AIGenerateImageRequest,
        client: any NetworkClient
    ) -> AsyncThrowingStream<AIImageEvent, any Error>
}

public extension RemoteImageProvider {
    func generateImageStream(
        _ request: AIGenerateImageRequest,
        client: any NetworkClient
    ) -> AsyncThrowingStream<AIImageEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let images = try await generateImage(request, client: client)
                    continuation.yield(.done(images: images, backend: backendID))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A reusable remote-image `AIBackend`: wraps a ``RemoteImageProvider`` + an
/// injected ``NetworkClient`` and maps them onto the `ai.generateImage` /
/// `ai.generateImageStream` surface, owning the cross-cutting concerns once so
/// each provider is small.
///
/// Drops straight into the shipped `MultiModelImageBackend` switcher as one more
/// entry — remote and local models in the same dropdown, routed by
/// `request.model`, with no switcher change (a remote backend inherits the no-op
/// `unload()`, so the switcher's evict-on-switch machinery costs it nothing).
///
/// Wire the platform client the same way as any backend:
/// `RemoteImageBackend(provider: ImagenProvider(apiKey: { … }), client: net)`,
/// where `net` is `URLSessionNetworkClient()` on desktop/Apple or
/// `AndroidNetworkClient()` on Android.
public final class RemoteImageBackend: AIBackend, @unchecked Sendable {
    private let provider: any RemoteImageProvider
    private let client: any NetworkClient

    public init(provider: any RemoteImageProvider, client: any NetworkClient) {
        self.provider = provider
        self.client = client
    }

    /// The catalog this backend serves — handy when composing it into a
    /// `MultiModelImageBackend` (`.init(backend.modelInfo, backend)` per model).
    public var models: [AIModelInfo] {
        provider.models
    }

    public func info() async -> AICapabilities {
        let caps = provider.models.reduce(into: Set<AIModelCapability>()) { $0.formUnion($1.capabilities) }
        let available = provider.models.contains { $0.availability.isAvailableNow }
        return AICapabilities(
            available: available,
            backend: provider.backendID,
            model: provider.models.first?.id,
            imageGeneration: caps.contains(.imageGeneration),
            imageEditing: caps.contains(.imageEdit) || caps.contains(.inpaint),
            models: provider.models
        )
    }

    /// Image-only backend: text generation isn't offered here (compose it with a
    /// text backend via `MultiModelImageBackend` / an app-side composite).
    public func generate(_: AIGenerateRequest) async throws -> AIGenerateResult {
        throw AIError.unsupportedPlatform("this backend generates images only")
    }

    public func generateImage(_ request: AIGenerateImageRequest) async throws -> AIGenerateImageResult {
        let images = try await provider.generateImage(request, client: client)
        return AIGenerateImageResult(images: images, backend: provider.backendID)
    }

    public func generateImageStream(
        _ request: AIGenerateImageRequest
    ) -> AsyncThrowingStream<AIImageEvent, any Error> {
        provider.generateImageStream(request, client: client)
    }

    /// A remote model has nothing to download — it's "ready" as soon as its
    /// service is reachable. Report `done` immediately so a UI that runs an
    /// `ai.ensureModel` "prepare" step before generating (as the switcher demo
    /// does for the downloadable on-device models) completes at once instead of
    /// hanging on the inherited default (which throws `.unsupportedPlatform`).
    public func ensureModel(_: AIEnsureModelRequest) -> AsyncThrowingStream<AIDownloadEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.done)
            continuation.finish()
        }
    }
}
