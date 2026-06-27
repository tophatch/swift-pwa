import Foundation
import SwiftPWACore
@testable import SwiftPWALlama
import Testing

/// End-to-end generation tests against a real GGUF model. They **skip** unless
/// a model is available (mirroring the Foundation Models e2e), so CI without a
/// model stays green while a dev box with one gets real coverage.
///
/// Point the tests at a model by setting `SWIFT_PWA_LLAMA_TEST_MODEL` to a
/// `.gguf` path (a small instruct model like SmolLM2-135M works well).
@Suite("LlamaBackend end-to-end")
struct LlamaBackendTests {
    private func modelPath() -> String? {
        if let p = ProcessInfo.processInfo.environment["SWIFT_PWA_LLAMA_TEST_MODEL"],
           FileManager.default.fileExists(atPath: p)
        {
            return p
        }
        return nil
    }

    @Test("info reports available + llama backend id when a model is present")
    func info() async {
        guard let path = modelPath() else { return }
        let backend = LlamaBackend(modelPath: path)
        let caps = await backend.info()
        #expect(caps.available)
        #expect(caps.backend == AIBackendID.gemmaLlamaCpp)
        #expect(caps.streaming)
        #expect(caps.structuredOutput)
    }

    @Test("info reports unavailable for a missing model")
    func infoMissing() async {
        let backend = LlamaBackend(modelPath: "/no/such/model.gguf")
        let caps = await backend.info()
        #expect(!caps.available)
    }

    @Test("generate completes a factual prompt")
    func generate() async throws {
        guard let path = modelPath() else { return }
        let backend = LlamaBackend(modelPath: path)
        let result = try await backend.generate(
            AIGenerateRequest(prompt: "The capital of France is the city of", maxTokens: 24, temperature: 0)
        )
        #expect(result.backend == AIBackendID.gemmaLlamaCpp)
        #expect(result.text.localizedCaseInsensitiveContains("Paris"))
    }

    @Test("generateStream yields deltas then completes")
    func stream() async throws {
        guard let path = modelPath() else { return }
        let backend = LlamaBackend(modelPath: path)
        var deltas = 0
        var sawDone = false
        var text = ""
        for try await chunk in backend.generateStream(
            AIGenerateRequest(prompt: "Count to three:", maxTokens: 24, temperature: 0)
        ) {
            if chunk.type == "delta" { deltas += 1; text += chunk.text ?? "" }
            if chunk.type == "done" { sawDone = true }
        }
        #expect(deltas > 0)
        #expect(sawDone)
        #expect(!text.isEmpty)
    }

    @Test("generateJSON returns schema-valid structured output")
    func generateJSON() async throws {
        guard let path = modelPath() else { return }
        let backend = LlamaBackend(modelPath: path)
        let schema = JSONValue.object([
            "type": .string("object"),
            "required": .array([.string("city"), .string("country")]),
            "properties": .object([
                "city": .object(["type": .string("string")]),
                "country": .object(["type": .string("string")])
            ])
        ])
        let value = try await backend.generateJSON(
            AIGenerateJSONRequest(
                prompt: "Return the capital city of France and its country as JSON.",
                schema: schema
            )
        )
        guard case let .object(obj) = value else {
            Issue.record("expected a JSON object, got \(value)")
            return
        }
        #expect(obj["city"] != nil)
        #expect(obj["country"] != nil)
    }
}
