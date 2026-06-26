import Foundation
import SwiftPWACore
@testable import SwiftPWAFoundationModels
import Testing

#if canImport(FoundationModels)
    import FoundationModels
#endif

@Suite("FoundationModelsBackend")
struct FoundationModelsBackendTests {
    // MARK: - Always (no model needed)

    @Test("info reports the apple-foundation-models backend id")
    func infoBackendId() async {
        let caps = await FoundationModelsBackend().info()
        #expect(caps.backend == AIBackendID.appleFoundationModels)
        // The structured/streaming guarantees hold exactly when available.
        if caps.available {
            #expect(caps.structuredOutput)
            #expect(caps.streaming)
        }
    }

    @Test("the text-only system model leaves image/audio capabilities off")
    func textOnlyCapabilities() async {
        let caps = await FoundationModelsBackend().info()
        #expect(caps.vision == false)
        #expect(caps.imageGeneration == false)
        #expect(caps.audioInput == false)
        #expect(caps.audioGeneration == false)
    }

    @Test("generateImage / generateAudio are unsupported (inherit the defaults)")
    func unsupportedGeneration() async {
        let backend = FoundationModelsBackend()
        await #expect(throws: AIError.self) { _ = try await backend.generateImage(.init(prompt: "x")) }
        await #expect(throws: AIError.self) { _ = try await backend.generateAudio(.init(prompt: "x")) }
    }

    // MARK: - End-to-end (only when the system model is available)

    @Test("generate + structured JSON round-trip on-device")
    func endToEnd() async throws {
        let backend = FoundationModelsBackend()
        guard await backend.info().available else {
            // No system model on this host (CI, Apple Intelligence off, or
            // still downloading) — the contract path is covered elsewhere.
            return
        }

        let text = try await backend.generate(.init(prompt: "Reply with the single word: hello"))
        #expect(!text.text.isEmpty)
        #expect(text.backend == AIBackendID.appleFoundationModels)

        let schema = JSONValue.object([
            "type": .string("object"),
            "required": .array([.string("city")]),
            "properties": .object(["city": .object(["type": .string("string")])])
        ])
        let json = try await backend.generateJSON(.init(prompt: "Name any European capital city.", schema: schema))
        guard case let .object(obj) = json else { Issue.record("expected a JSON object"); return }
        #expect(obj["city"] != nil)
    }

    // MARK: - Schema / content conversion (model not required)

    #if canImport(FoundationModels)
        @Test("jsonValue maps a GeneratedContent structure to a JSONValue object")
        func contentConversion() {
            guard #available(macOS 26, iOS 26, *) else { return }
            let content = GeneratedContent(properties: ["name": "Ada", "tags": ["a", "b"]])
            let value = FoundationModelsBackend.jsonValue(from: content)
            guard case let .object(obj) = value else { Issue.record("expected an object"); return }
            #expect(obj["name"] == .string("Ada"))
            #expect(obj["tags"] == .array([.string("a"), .string("b")]))
        }

        @Test("generationSchema builds from a nested JSON schema without throwing")
        func schemaBuild() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let schema = JSONValue.object([
                "type": .string("object"),
                "required": .array([.string("title")]),
                "properties": .object([
                    "title": .object(["type": .string("string")]),
                    "count": .object(["type": .string("integer")]),
                    "rating": .object(["type": .string("number")]),
                    "done": .object(["type": .string("boolean")]),
                    "tags": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                    "tier": .object(["enum": .array([.string("free"), .string("pro")])])
                ])
            ])
            _ = try FoundationModelsBackend.generationSchema(from: schema)
        }
    #endif
}
