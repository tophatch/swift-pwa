import Foundation
@testable import SwiftPWACore
import Testing

// MARK: - Stub backend

/// A minimal image backend that stamps its own id into every result, so a
/// test can see which backend a routed call reached. `ensureModel` yields a
/// per-backend `marker` byte count for the same reason.
private struct StubImageBackend: AIBackend {
    let id: String
    var marker: Int64 = 0
    var streaming = false

    func info() async -> AICapabilities {
        AICapabilities(available: true, backend: id, model: id, streaming: streaming, voiceCloning: false)
    }

    func generate(_: AIGenerateRequest) async throws -> AIGenerateResult {
        AIGenerateResult(text: "gen:\(id)", backend: id)
    }

    func generateImage(_: AIGenerateImageRequest) async throws -> AIGenerateImageResult {
        AIGenerateImageResult(images: [AIGeneratedImage(dataBase64: id, mimeType: "image/png")], backend: id)
    }

    func ensureModel(_: AIEnsureModelRequest) -> AsyncThrowingStream<AIDownloadEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.progress(bytesDone: marker, totalBytes: nil))
            continuation.yield(.done)
            continuation.finish()
        }
    }
}

private func entry(
    _ id: String,
    caps: Set<AIModelCapability> = [.imageGeneration],
    availability: AIModelAvailability = .ready,
    offline: Bool = true,
    license: String? = nil,
    marker: Int64 = 0
) -> MultiModelImageBackend.Entry {
    MultiModelImageBackend.Entry(
        AIModelInfo(
            id: id, label: id.uppercased(), capabilities: caps,
            availability: availability, offlineCapable: offline, license: license
        ),
        StubImageBackend(id: id, marker: marker)
    )
}

// MARK: - Routing

struct MultiModelImageBackendTests {
    @Test func generateImageRoutesByModelID() async throws {
        let backend = MultiModelImageBackend([entry("a"), entry("b")], default: "a")

        let toB = try await backend.generateImage(AIGenerateImageRequest(prompt: "x", model: "b"))
        #expect(toB.backend == "b")
        #expect(toB.images.first?.dataBase64 == "b")

        let toA = try await backend.generateImage(AIGenerateImageRequest(prompt: "x", model: "a"))
        #expect(toA.backend == "a")
    }

    @Test func nilModelUsesDefault() async throws {
        let backend = MultiModelImageBackend([entry("a"), entry("b")], default: "b")
        let result = try await backend.generateImage(AIGenerateImageRequest(prompt: "x")) // no model
        #expect(result.backend == "b")
    }

    @Test func unknownModelIDThrows() async {
        let backend = MultiModelImageBackend([entry("a")], default: "a")
        await #expect(throws: AIError.self) {
            _ = try await backend.generateImage(AIGenerateImageRequest(prompt: "x", model: "nope"))
        }
    }

    @Test func generateImageStreamRoutes() async throws {
        let backend = MultiModelImageBackend([entry("a"), entry("b")], default: "a")
        var doneBackend: String?
        for try await event in backend.generateImageStream(AIGenerateImageRequest(prompt: "x", model: "b")) {
            if event.type == "done" { doneBackend = event.backend }
        }
        #expect(doneBackend == "b")
    }

    @Test func ensureModelRoutesByModelID() async throws {
        let backend = MultiModelImageBackend(
            [entry("a", marker: 11), entry("b", marker: 22)], default: "a"
        )
        var markers: [Int64] = []
        for try await event in backend.ensureModel(AIEnsureModelRequest(model: "b")) {
            if event.type == "progress", let b = event.bytesDone { markers.append(b) }
        }
        #expect(markers == [22])
    }

    @Test func unknownModelInStreamFinishesWithError() async {
        let backend = MultiModelImageBackend([entry("a")], default: "a")
        await #expect(throws: AIError.self) {
            for try await _ in backend.generateImageStream(AIGenerateImageRequest(prompt: "x", model: "zzz")) {}
        }
    }

    @Test func textVerbDelegatesToDefault() async throws {
        let backend = MultiModelImageBackend([entry("a"), entry("b")], default: "b")
        let result = try await backend.generate(AIGenerateRequest(prompt: "hi"))
        #expect(result.text == "gen:b") // routed to the default, not "a"
    }

    // MARK: - Aggregate info()

    @Test func infoAggregatesModelsAndFlags() async {
        let backend = MultiModelImageBackend(
            [
                entry("txt", caps: [.textGeneration]),
                entry("sd", caps: [.imageGeneration, .imageEdit]),
                entry("lama", caps: [.inpaint]),
                entry("sam", caps: [.vision])
            ],
            default: "sd"
        )
        let info = await backend.info()
        #expect(info.backend == AIBackendID.multiModel)
        #expect(info.model == "sd")
        #expect(info.available)
        #expect(info.imageGeneration) // sd
        #expect(info.imageEditing) // sd (imageEdit) + lama (inpaint)
        #expect(info.vision) // sam
        #expect(info.models?.count == 4)
        #expect(info.models?.map(\.id) == ["txt", "sd", "lama", "sam"]) // order preserved
    }

    @Test func infoUnavailableWhenAllNeedSetup() async {
        let backend = MultiModelImageBackend(
            [entry("cloud", availability: .needsSetup(reason: "Add an API key"), offline: false)],
            default: "cloud"
        )
        let info = await backend.info()
        #expect(!info.available)
    }

    @Test func infoAvailableWhenModelIsDownloadable() async {
        let backend = MultiModelImageBackend(
            [entry("local", availability: .downloadable(bytes: 2_000_000_000))],
            default: "local"
        )
        let info = await backend.info()
        #expect(info.available) // downloadable still counts (arrives via ai.ensureModel)
    }
}

// MARK: - Codable / wire shape

struct AIModelInfoCodableTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test func capabilitiesEncodeAsKebabStrings() throws {
        let data = try JSONEncoder().encode([AIModelCapability.imageEdit, .textToSpeech, .inpaint])
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("image-edit"))
        #expect(json.contains("text-to-speech"))
        #expect(json.contains("inpaint"))
    }

    @Test func availabilityReadyRoundTrips() throws {
        let value = AIModelAvailability.ready
        #expect(try roundTrip(value) == value)
        let json = try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
        #expect(json.contains("\"kind\""))
        #expect(json.contains("ready"))
    }

    @Test func availabilityDownloadableRoundTrips() throws {
        let value = AIModelAvailability.downloadable(bytes: 1_720_180_719)
        #expect(try roundTrip(value) == value)
        let json = try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
        #expect(json.contains("downloadable"))
        #expect(json.contains("1720180719"))
    }

    @Test func availabilityDownloadableNilBytesRoundTrips() throws {
        let value = AIModelAvailability.downloadable(bytes: nil)
        #expect(try roundTrip(value) == value)
    }

    @Test func availabilityNeedsSetupRoundTrips() throws {
        let value = AIModelAvailability.needsSetup(reason: "Add an API key in Settings")
        #expect(try roundTrip(value) == value)
        let json = try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
        #expect(json.contains("needsSetup"))
        #expect(json.contains("Add an API key"))
    }

    @Test func modelInfoRoundTrips() throws {
        let value = AIModelInfo(
            id: "lcm-dreamshaper",
            label: "LCM Dreamshaper",
            capabilities: [.imageGeneration, .imageEdit],
            availability: .downloadable(bytes: 2_067_793_994),
            offlineCapable: true,
            license: "OpenRAIL-M"
        )
        #expect(try roundTrip(value) == value)
    }

    @Test func capabilitiesFlowThroughAICapabilities() throws {
        let caps = AICapabilities(
            available: true, backend: AIBackendID.multiModel, model: "sd",
            imageGeneration: true,
            models: [
                AIModelInfo(
                    id: "sd", label: "SD", capabilities: [.imageGeneration],
                    availability: .ready, offlineCapable: true
                )
            ]
        )
        let decoded = try roundTrip(caps)
        #expect(decoded.models?.first?.id == "sd")
        #expect(decoded.models?.first?.capabilities == [.imageGeneration])
    }
}
