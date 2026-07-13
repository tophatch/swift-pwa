import Foundation
@testable import SwiftPWACore
import Testing

// MARK: - Test doubles

/// A backend with configurable capabilities that records the last image request
/// it received and streams a progress + done for it, so the adapter's mapping and
/// event bridging are observable.
private final class RecordingBackend: AIBackend, @unchecked Sendable {
    let caps: AICapabilities
    private let lock = NSLock()
    private var _lastRequest: AIGenerateImageRequest?
    var lastRequest: AIGenerateImageRequest? {
        lock.withLock { _lastRequest }
    }

    init(_ caps: AICapabilities) { self.caps = caps }

    func info() async -> AICapabilities { caps }

    func generate(_: AIGenerateRequest) async throws -> AIGenerateResult {
        AIGenerateResult(text: "", backend: caps.backend)
    }

    func generateImageStream(_ request: AIGenerateImageRequest) -> AsyncThrowingStream<AIImageEvent, any Error> {
        lock.withLock { _lastRequest = request }
        let backend = caps.backend
        return AsyncThrowingStream { continuation in
            continuation.yield(.progress(step: 1, totalSteps: 4))
            continuation.yield(.progress(step: 2, totalSteps: 4))
            let image = AIGeneratedImage(dataBase64: "IMG", mimeType: "image/png", seed: request.seed)
            continuation.yield(.done(images: [image], backend: backend))
            continuation.finish()
        }
    }

    func ensureModel(_: AIEnsureModelRequest) -> AsyncThrowingStream<AIDownloadEvent, any Error> {
        AsyncThrowingStream { $0.yield(.done); $0.finish() }
    }
}

/// A no-op `NetworkClient` — the adapter ignores it (on-device has no endpoint).
private struct NoopClient: NetworkClient {
    func send(_: NetRequest) async throws -> NetResponse { NetResponse(status: 200) }
    func download(_: NetDownloadRequest) -> AsyncThrowingStream<NetDownloadEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private func placeholderConfig(inputs: [String: JSONValue] = [:]) -> AIWorkflowConfig {
    AIWorkflowConfig(connection: AIConnection(baseURL: URL(string: "about:blank")!), inputs: inputs)
}

private func collect(
    _ stream: AsyncThrowingStream<AIRunEvent, any Error>
) async throws -> [AIRunEvent] {
    var events: [AIRunEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

struct AIBackendWorkflowProviderTests {
    @Test func describeInputsForImageGeneration() async throws {
        let backend = RecordingBackend(AICapabilities(
            available: true, backend: "sd", imageGeneration: true
        ))
        let provider = AIBackendWorkflowProvider(providerID: "on-device", backend: backend)
        let schema = try await provider.describeInputs(config: placeholderConfig(), client: NoopClient())

        #expect(!schema.degraded)
        #expect(schema.inputs.map(\.key) == ["prompt", "negativePrompt", "steps", "guidanceScale", "seed", "count"])
    }

    @Test func describeInputsForPureInpaint() async throws {
        // imageEditing only (LaMa) → just image + mask, no prompt/steps.
        let backend = RecordingBackend(AICapabilities(
            available: true, backend: "lama", imageEditing: true
        ))
        let provider = AIBackendWorkflowProvider(providerID: "on-device", backend: backend)
        let schema = try await provider.describeInputs(config: placeholderConfig(), client: NoopClient())

        #expect(schema.inputs.map(\.key) == ["image", "mask"])
        let image = try #require(schema.inputs.first { $0.key == "image" })
        #expect(image.type == .image)
        #expect(image.isImage)
        let mask = try #require(schema.inputs.first { $0.key == "mask" })
        #expect(mask.type == .mask)
    }

    @Test func describeInputsAdvertisesModelEnum() async throws {
        let models = [
            AIModelInfo(
                id: "a",
                label: "A",
                capabilities: [.imageGeneration],
                availability: .ready,
                offlineCapable: true
            ),
            AIModelInfo(
                id: "b",
                label: "B",
                capabilities: [.imageGeneration],
                availability: .ready,
                offlineCapable: true
            )
        ]
        let backend = RecordingBackend(AICapabilities(
            available: true, backend: "sd", imageGeneration: true, imageEditing: true, models: models
        ))
        let provider = AIBackendWorkflowProvider(providerID: "on-device", backend: backend)
        let schema = try await provider.describeInputs(config: placeholderConfig(), client: NoopClient())

        let model = try #require(schema.inputs.first { $0.key == "model" })
        #expect(model.type == .enum)
        #expect(model.options == ["a", "b"])
        // Editing backend also contributes image + mask.
        let keys: [String] = schema.inputs.map(\.key)
        #expect(keys.contains("image"))
        #expect(keys.contains("mask"))
    }

    @Test func runMapsInputsAndBridgesEvents() async throws {
        let backend = RecordingBackend(AICapabilities(
            available: true, backend: "sd", imageGeneration: true
        ))
        let provider = AIBackendWorkflowProvider(providerID: "on-device", backend: backend)
        let config = placeholderConfig(inputs: [
            "prompt": .string("a fox"),
            "steps": .number(8),
            "guidanceScale": .number(1.5),
            "seed": .number(42),
            "count": .number(1)
        ])
        let events = try await collect(provider.runWorkflow(config: config, client: NoopClient()))

        // The backend saw the mapped request.
        let request = try #require(backend.lastRequest)
        #expect(request.prompt == "a fox")
        #expect(request.steps == 8)
        #expect(request.guidanceScale == 1.5)
        #expect(request.seed == 42)

        // Events: progress (×2) → image → done, with per-step value/max.
        let progresses = events.filter { $0.type == .progress }
        #expect(progresses.count == 2)
        #expect(progresses.first?.value == 1)
        #expect(progresses.first?.max == 4)
        let image = try #require(events.first { $0.type == .image })
        #expect(image.image?.dataBase64 == "IMG")
        #expect(image.image?.seed == 42)
        #expect(events.last?.type == .done)
    }

    @Test func runBuildsImageFromInputObject() async throws {
        let backend = RecordingBackend(AICapabilities(
            available: true, backend: "lama", imageEditing: true
        ))
        let provider = AIBackendWorkflowProvider(providerID: "on-device", backend: backend)
        let config = placeholderConfig(inputs: [
            "image": .object(["dataBase64": .string("SRC"), "mimeType": .string("image/png")]),
            "mask": .object(["path": .string("/tmp/mask.png")])
        ])
        _ = try await collect(provider.runWorkflow(config: config, client: NoopClient()))

        let request = try #require(backend.lastRequest)
        #expect(request.image?.dataBase64 == "SRC")
        #expect(request.image?.mimeType == "image/png")
        #expect(request.mask?.path == "/tmp/mask.png")
    }
}
