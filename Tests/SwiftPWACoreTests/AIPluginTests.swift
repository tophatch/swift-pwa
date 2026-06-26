import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

// MARK: - Test backends

/// Returns queued canned text from `generate`, so the shared
/// `generateJSON` fallback (and the default `generateStream`) can be
/// exercised without a real model. One reply per `generate` call, then the
/// last reply repeats.
private final class CannedBackend: AIBackend, @unchecked Sendable {
    private let replies: [String]
    private let caps: AICapabilities
    /// Mutated only from the serial test dispatch; `@unchecked Sendable`
    /// suppresses the (here unreachable) data-race check.
    private(set) var generateCalls = 0

    init(_ replies: [String], backend: String = "canned") {
        self.replies = replies
        caps = AICapabilities(available: true, backend: backend, model: "canned", streaming: false)
    }

    func info() async -> AICapabilities { caps }

    func generate(_: AIGenerateRequest) async throws -> AIGenerateResult {
        let i = generateCalls
        generateCalls += 1
        let text = i < replies.count ? replies[i] : (replies.last ?? "")
        return AIGenerateResult(text: text, backend: caps.backend)
    }
}

/// A backend that streams several deltas and answers `generateJSON`
/// natively — to prove the protocol's overrides win over the defaults.
private struct StreamingBackend: AIBackend {
    func info() async -> AICapabilities {
        AICapabilities(available: true, backend: "streaming", model: "s", streaming: true, structuredOutput: true)
    }

    func generate(_: AIGenerateRequest) async throws -> AIGenerateResult {
        AIGenerateResult(text: "ABC", backend: "streaming")
    }

    func generateStream(_: AIGenerateRequest) -> AsyncThrowingStream<AIChunk, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.delta("A"))
            continuation.yield(.delta("B"))
            continuation.yield(.delta("C"))
            continuation.yield(.done)
            continuation.finish()
        }
    }

    func generateJSON(_: AIGenerateJSONRequest) async throws -> JSONValue {
        .object(["native": .bool(true)])
    }
}

/// Vision-capable: echoes the number of input images into the generated
/// text, so image threading through `generate` (and the `generateJSON`
/// fallback) is observable.
private struct VisionEchoBackend: AIBackend {
    func info() async -> AICapabilities {
        AICapabilities(available: true, backend: "vision", vision: true)
    }

    func generate(_ request: AIGenerateRequest) async throws -> AIGenerateResult {
        AIGenerateResult(text: "images:\(request.images?.count ?? 0)", backend: "vision")
    }
}

/// Text→image backend using the default (single `done`) stream.
private struct ImageBackend: AIBackend {
    func info() async -> AICapabilities {
        AICapabilities(available: true, backend: AIBackendID.stableDiffusionMLX, imageGeneration: true)
    }

    func generate(_: AIGenerateRequest) async throws -> AIGenerateResult {
        AIGenerateResult(text: "", backend: AIBackendID.stableDiffusionMLX)
    }

    func generateImage(_ request: AIGenerateImageRequest) async throws -> AIGenerateImageResult {
        AIGenerateImageResult(
            images: [AIGeneratedImage(dataBase64: "iVBORw0=", mimeType: "image/png", seed: request.seed ?? 42)],
            backend: AIBackendID.stableDiffusionMLX
        )
    }
}

/// Text→image backend that reports per-step denoising progress.
private struct StreamingImageBackend: AIBackend {
    func info() async -> AICapabilities {
        AICapabilities(available: true, backend: "sd", imageGeneration: true)
    }

    func generate(_: AIGenerateRequest) async throws -> AIGenerateResult {
        AIGenerateResult(text: "", backend: "sd")
    }

    func generateImage(_: AIGenerateImageRequest) async throws -> AIGenerateImageResult {
        AIGenerateImageResult(images: [AIGeneratedImage(dataBase64: "final")], backend: "sd")
    }

    func generateImageStream(_: AIGenerateImageRequest) -> AsyncThrowingStream<AIImageEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.progress(step: 1, totalSteps: 2))
            continuation.yield(.progress(step: 2, totalSteps: 2))
            continuation.yield(.done(images: [AIGeneratedImage(dataBase64: "final")], backend: "sd"))
            continuation.finish()
        }
    }
}

@Suite("AIPlugin")
@MainActor
struct AIPluginTests {
    private func app(_ backend: any AIBackend) -> MockAppContext {
        let app = MockAppContext()
        app.use(AIPlugin(backend))
        return app
    }

    private func dispatch(_ app: MockAppContext, _ command: String, _ payload: String) async -> InvocationResult {
        let inv = Invocation(id: 1, command: command, payload: Data(payload.utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        return await app.registry.dispatch(ctx)
    }

    private func collect(_ stream: AsyncThrowingStream<Data, any Error>) async throws -> [Data] {
        var out: [Data] = []
        for try await chunk in stream { out.append(chunk) }
        return out
    }

    // MARK: - NoneBackend (the default-install contract)

    @Test("ai.info reports available:false with NoneBackend")
    func infoNone() async throws {
        let result = await dispatch(app(NoneBackend()), "ai.info", "{}")
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let caps = try JSONDecoder().decode(AICapabilities.self, from: data)
        #expect(caps.available == false)
        #expect(caps.backend == AIBackendID.none)
    }

    @Test("AIPlugin() defaults to NoneBackend")
    func defaultInit() async throws {
        let app = MockAppContext()
        app.use(AIPlugin())
        let result = await dispatch(app, "ai.info", "{}")
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        #expect(try JSONDecoder().decode(AICapabilities.self, from: data).available == false)
    }

    @Test("ai.generate maps unavailability to E_AI_UNAVAILABLE")
    func generateNone() async {
        let result = await dispatch(app(NoneBackend()), "ai.generate", #"{"prompt":"hi"}"#)
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.code == AIError.unavailableCode)
    }

    @Test("ai.generateStream surfaces unavailability as a stream error with the stable code")
    func generateStreamNone() async throws {
        let result = await dispatch(app(NoneBackend()), "ai.generateStream", #"{"prompt":"hi"}"#)
        guard case let .stream(stream) = result else { Issue.record("expected stream"); return }
        do {
            for try await _ in stream {}
            Issue.record("expected the stream to throw")
        } catch let err as BridgeError {
            #expect(err.code == AIError.unavailableCode)
        }
    }

    @Test("ai.ensureModel is reserved — reports E_UNIMPLEMENTED")
    func ensureModelReserved() async throws {
        let result = await dispatch(app(NoneBackend()), "ai.ensureModel", "{}")
        guard case let .stream(stream) = result else { Issue.record("expected stream"); return }
        do {
            for try await _ in stream {}
            Issue.record("expected the reserved stream to throw")
        } catch let err as BridgeError {
            #expect(err.code == BridgeError.unimplemented)
        }
    }

    // MARK: - A working backend

    @Test("ai.generate returns text and backend id")
    func generateOK() async throws {
        let result = await dispatch(app(CannedBackend(["hello world"])), "ai.generate", #"{"prompt":"x"}"#)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(AIGenerateResult.self, from: data)
        #expect(out.text == "hello world")
        #expect(out.backend == "canned")
    }

    @Test("default generateStream wraps generate as one delta + done")
    func defaultStream() async throws {
        let result = await dispatch(app(CannedBackend(["hi"])), "ai.generateStream", #"{"prompt":"x"}"#)
        guard case let .stream(stream) = result else { Issue.record("expected stream"); return }
        let chunks = try await collect(stream).map { try JSONDecoder().decode(AIChunk.self, from: $0) }
        #expect(chunks == [.delta("hi"), .done])
    }

    @Test("a streaming backend's override yields incremental deltas")
    func overriddenStream() async throws {
        let result = await dispatch(app(StreamingBackend()), "ai.generateStream", #"{"prompt":"x"}"#)
        guard case let .stream(stream) = result else { Issue.record("expected stream"); return }
        let chunks = try await collect(stream).map { try JSONDecoder().decode(AIChunk.self, from: $0) }
        #expect(chunks == [.delta("A"), .delta("B"), .delta("C"), .done])
    }

    @Test("ai.generateJSON returns the parsed object via the fallback")
    func generateJSONFallback() async throws {
        let backend = CannedBackend([#"{"name":"Ada"}"#])
        let payload = #"{"prompt":"x","schema":{"type":"object","required":["name"]}}"#
        let result = await dispatch(app(backend), "ai.generateJSON", payload)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value == .object(["name": .string("Ada")]))
        #expect(backend.generateCalls == 1)
    }

    @Test("ai.generateJSON uses a backend's native override (no fallback prompt)")
    func generateJSONNative() async throws {
        let payload = #"{"prompt":"x","schema":{"type":"object"}}"#
        let result = await dispatch(app(StreamingBackend()), "ai.generateJSON", payload)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == .object(["native": .bool(true)]))
    }

    @Test("ai.generateJSON failing repair maps to E_AI_STRUCTURED_OUTPUT")
    func generateJSONFails() async {
        let backend = CannedBackend(["not json", "still not json"])
        let payload = #"{"prompt":"x","schema":{"type":"object","required":["name"]}}"#
        let result = await dispatch(app(backend), "ai.generateJSON", payload)
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.code == AIError.structuredOutputCode)
        #expect(backend.generateCalls == 2) // initial + one repair
    }

    // MARK: - Vision input

    @Test("ai.info reports the vision flag")
    func infoVision() async throws {
        let result = await dispatch(app(VisionEchoBackend()), "ai.info", "{}")
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let caps = try JSONDecoder().decode(AICapabilities.self, from: data)
        #expect(caps.vision == true)
        #expect(caps.imageGeneration == false)
    }

    @Test("image inputs thread through ai.generate to the backend")
    func visionImagesThread() async throws {
        let payload = #"{"prompt":"describe","images":[{"dataBase64":"aaa"},{"path":"/p.png"}]}"#
        let result = await dispatch(app(VisionEchoBackend()), "ai.generate", payload)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        #expect(try JSONDecoder().decode(AIGenerateResult.self, from: data).text == "images:2")
    }

    // MARK: - Image generation

    @Test("ai.info reports the imageGeneration flag")
    func infoImageGeneration() async throws {
        let result = await dispatch(app(ImageBackend()), "ai.info", "{}")
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        #expect(try JSONDecoder().decode(AICapabilities.self, from: data).imageGeneration == true)
    }

    @Test("ai.generateImage on NoneBackend reports E_AI_UNAVAILABLE")
    func generateImageNone() async {
        let result = await dispatch(app(NoneBackend()), "ai.generateImage", #"{"prompt":"a cat"}"#)
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.code == AIError.unavailableCode)
    }

    @Test("ai.generateImage on a text-only backend reports E_UNIMPLEMENTED")
    func generateImageUnsupported() async {
        let result = await dispatch(app(CannedBackend(["hi"])), "ai.generateImage", #"{"prompt":"a cat"}"#)
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.code == BridgeError.unimplemented)
    }

    @Test("ai.generateImage returns images, echoing the seed and backend")
    func generateImageOK() async throws {
        let result = await dispatch(app(ImageBackend()), "ai.generateImage", #"{"prompt":"a cat","seed":7}"#)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(AIGenerateImageResult.self, from: data)
        #expect(out.backend == AIBackendID.stableDiffusionMLX)
        #expect(out.images.count == 1)
        #expect(out.images.first?.seed == 7)
        #expect(out.images.first?.mimeType == "image/png")
    }

    @Test("default generateImageStream emits a single done with the images")
    func defaultImageStream() async throws {
        let result = await dispatch(app(ImageBackend()), "ai.generateImageStream", #"{"prompt":"a cat"}"#)
        guard case let .stream(stream) = result else { Issue.record("expected stream"); return }
        let events = try await collect(stream).map { try JSONDecoder().decode(AIImageEvent.self, from: $0) }
        #expect(events.count == 1)
        #expect(events.first?.type == "done")
        #expect(events.first?.images?.count == 1)
    }

    @Test("an image backend's stream override emits per-step progress then done")
    func overriddenImageStream() async throws {
        let result = await dispatch(app(StreamingImageBackend()), "ai.generateImageStream", #"{"prompt":"a cat"}"#)
        guard case let .stream(stream) = result else { Issue.record("expected stream"); return }
        let events = try await collect(stream).map { try JSONDecoder().decode(AIImageEvent.self, from: $0) }
        #expect(events.map(\.type) == ["progress", "progress", "done"])
        #expect(events.first?.step == 1)
        #expect(events.last?.images?.first?.dataBase64 == "final")
    }
}

// MARK: - Fallback unit tests (no plugin, no backend)

@Suite("AIStructuredFallback")
struct AIStructuredFallbackTests {
    private let objectSchema = JSONValue.object([
        "type": .string("object"),
        "required": .array([.string("name")])
    ])

    @Test("plain JSON parses")
    func plain() {
        #expect(AIStructuredFallback.parseAndValidate(#"{"name":"x"}"#, schema: objectSchema)
            == .object(["name": .string("x")]))
    }

    @Test("markdown-fenced JSON is de-fenced")
    func fenced() {
        let text = "```json\n{\"name\":\"x\"}\n```"
        #expect(AIStructuredFallback.parseAndValidate(text, schema: objectSchema)
            == .object(["name": .string("x")]))
    }

    @Test("JSON embedded in prose is extracted by bracket span")
    func prose() {
        let text = "Sure! Here is the object you asked for: {\"name\":\"x\"} — hope that helps."
        #expect(AIStructuredFallback.parseAndValidate(text, schema: objectSchema)
            == .object(["name": .string("x")]))
    }

    @Test("a missing required key fails validation")
    func missingRequired() {
        #expect(AIStructuredFallback.parseAndValidate(#"{"other":1}"#, schema: objectSchema) == nil)
    }

    @Test("non-JSON returns nil")
    func notJSON() {
        #expect(AIStructuredFallback.parseAndValidate("definitely not json", schema: objectSchema) == nil)
    }

    @Test("run repairs after one bad reply")
    func repairs() async throws {
        let replies = ["garbage", #"{"name":"fixed"}"#]
        var i = 0
        let request = AIGenerateJSONRequest(prompt: "x", schema: objectSchema)
        let value = try await AIStructuredFallback.run(request) { _ in
            defer { i += 1 }
            return AIGenerateResult(text: replies[i], backend: "t")
        }
        #expect(value == .object(["name": .string("fixed")]))
        #expect(i == 2)
    }

    @Test("run throws after a failed repair")
    func givesUp() async {
        let request = AIGenerateJSONRequest(prompt: "x", schema: objectSchema)
        await #expect(throws: AIError.self) {
            _ = try await AIStructuredFallback.run(request) { _ in
                AIGenerateResult(text: "nope", backend: "t")
            }
        }
    }

    @Test("run threads input images through to generate (vision + structured)")
    func threadsImages() async throws {
        let request = AIGenerateJSONRequest(prompt: "x", schema: objectSchema, images: [.inline("abc"), .file("/p")])
        var seenImages: Int?
        _ = try await AIStructuredFallback.run(request) { generated in
            seenImages = generated.images?.count
            return AIGenerateResult(text: #"{"name":"x"}"#, backend: "t")
        }
        #expect(seenImages == 2)
    }
}

// MARK: - Codable round-trips (the wire contract)

@Suite("AI wire contract")
struct AIWireContractTests {
    @Test("AICapabilities round-trips (including vision / imageGeneration)")
    func capabilities() throws {
        let caps = AICapabilities(
            available: true, backend: "apple-foundation-models",
            model: "system", streaming: true, structuredOutput: true,
            vision: true, imageGeneration: false
        )
        let data = try JSONEncoder().encode(caps)
        let decoded = try JSONDecoder().decode(AICapabilities.self, from: data)
        #expect(decoded == caps)
        #expect(decoded.vision == true)
    }

    @Test("AIImage / AIGeneratedImage / image request round-trip")
    func imageTypes() throws {
        let img = AIImage.file("/photo.png", mimeType: "image/png")
        #expect(try JSONDecoder().decode(AIImage.self, from: JSONEncoder().encode(img)) == img)

        let req = AIGenerateImageRequest(prompt: "a cat", width: 512, height: 512, steps: 20, seed: 3, count: 2)
        #expect(try JSONDecoder().decode(AIGenerateImageRequest.self, from: JSONEncoder().encode(req)) == req)

        let gen = AIGeneratedImage(path: "/out/0.png", mimeType: "image/png", seed: 3)
        #expect(try JSONDecoder().decode(AIGeneratedImage.self, from: JSONEncoder().encode(gen)) == gen)
    }

    @Test("AIImageEvent progress and done round-trip")
    func imageEvents() throws {
        let progress = AIImageEvent.progress(step: 3, totalSteps: 20)
        #expect(try JSONDecoder().decode(AIImageEvent.self, from: JSONEncoder().encode(progress)) == progress)
        let done = AIImageEvent.done(images: [AIGeneratedImage(dataBase64: "x")], backend: "sd")
        #expect(try JSONDecoder().decode(AIImageEvent.self, from: JSONEncoder().encode(done)) == done)
    }

    @Test("AIChunk done has a null text field")
    func chunkDone() throws {
        let data = try JSONEncoder().encode(AIChunk.done)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["type"] as? String == "done")
    }

    @Test("AIGenerateRequest omits nil optionals cleanly on decode")
    func requestDecodes() throws {
        let req = try JSONDecoder().decode(AIGenerateRequest.self, from: Data(#"{"prompt":"hi"}"#.utf8))
        #expect(req.prompt == "hi")
        #expect(req.system == nil)
        #expect(req.maxTokens == nil)
    }
}
