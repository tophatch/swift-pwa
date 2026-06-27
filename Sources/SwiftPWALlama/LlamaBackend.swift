import Foundation
import SwiftPWACore
import SwiftPWAModelStore

/// An `AIBackend` backed by **llama.cpp** running a GGUF model on-device
/// (Metal-accelerated on Apple). The portable counterpart to
/// `FoundationModelsBackend`: it runs anywhere we ship the prebuilt llama
/// xcframework and a GGUF model is present, independent of OS-level model
/// availability.
///
/// Opt in like any backend:
/// ```swift
/// import SwiftPWALlama
/// // A model already on disk:
/// ctx.use(AIPlugin(LlamaBackend(modelPath: "/path/to/model.gguf")))
/// // …or a downloadable model wired to ai.ensureModel:
/// ctx.use(AIPlugin(LlamaBackend(model: spec, cacheDirectory: dir)))
/// ```
///
/// Provides text (`generate`), token streaming (`generateStream`), and
/// **native schema-constrained** structured output (`generateJSON`, via a GBNF
/// grammar — `structuredOutput: true`) for the common JSON-Schema subset,
/// falling back to the shared prompt-and-validate path for schemas it can't
/// translate. Text-only for now, so vision / image / audio stay unsupported.
///
/// `Sendable` via its `LlamaEngine` actor, which serializes generation (one
/// `llama_context` can't be driven concurrently).
public struct LlamaBackend: AIBackend {
    private let engine: LlamaEngine
    private let modelName: String
    private let modelPath: String
    /// Set only for the downloadable tier — drives `ensureModel`.
    private let download: (downloader: ModelDownloader, spec: ModelSpec)?

    /// Back a model file already present on disk.
    public init(
        modelPath: String,
        modelName: String? = nil,
        contextLength: Int = 4096,
        gpuLayers: Int = 999
    ) {
        self.modelPath = modelPath
        self.modelName = modelName ?? URL(fileURLWithPath: modelPath).lastPathComponent
        download = nil
        var config = LlamaEngine.Config()
        config.contextLength = Int32(contextLength)
        config.gpuLayers = Int32(gpuLayers)
        engine = LlamaEngine(modelPath: modelPath, config: config)
    }

    /// Back a downloadable model: `ai.ensureModel` fetches `spec` into
    /// `cacheDirectory` (resumable, checksum-pinned via `ModelDownloader`);
    /// generation loads it from there once present.
    public init(
        model spec: ModelSpec,
        cacheDirectory: URL,
        modelName: String? = nil,
        contextLength: Int = 4096,
        gpuLayers: Int = 999
    ) {
        let downloader = ModelDownloader(directory: cacheDirectory)
        let resolved = downloader.localURL(for: spec)
        modelPath = resolved.path
        self.modelName = modelName ?? spec.fileName
        download = (downloader, spec)
        var config = LlamaEngine.Config()
        config.contextLength = Int32(contextLength)
        config.gpuLayers = Int32(gpuLayers)
        engine = LlamaEngine(modelPath: resolved.path, config: config)
    }

    public func info() async -> AICapabilities {
        AICapabilities(
            available: engine.modelFileExists(),
            backend: AIBackendID.gemmaLlamaCpp,
            model: modelName,
            streaming: true,
            structuredOutput: true
        )
    }

    public func generate(_ request: AIGenerateRequest) async throws -> AIGenerateResult {
        let text = try await collect(request, grammar: nil)
        return AIGenerateResult(text: text, backend: AIBackendID.gemmaLlamaCpp)
    }

    public func generateStream(_ request: AIGenerateRequest) -> AsyncThrowingStream<AIChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await engine.run(
                        system: request.system,
                        prompt: request.prompt,
                        maxTokens: request.maxTokens,
                        temperature: request.temperature,
                        grammar: nil
                    ) { piece in
                        if !piece.isEmpty { continuation.yield(.delta(piece)) }
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch let error as AIError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: AIError.generationFailed("\(error)"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func generateJSON(_ request: AIGenerateJSONRequest) async throws -> JSONValue {
        // Native path: a GBNF grammar constrains decoding to the schema.
        guard let grammar = GBNF.grammar(from: request.schema) else {
            // Schema outside our GBNF subset — use the shared prompt-and-
            // validate fallback so the command still works (unconstrained).
            return try await AIStructuredFallback.run(request, generate: generate)
        }
        let text = try await collect(
            AIGenerateRequest(
                system: request.system,
                prompt: request.prompt,
                maxTokens: request.maxTokens,
                temperature: request.temperature ?? 0
            ),
            grammar: grammar
        )
        do {
            return try JSONValue.decode(Data(text.utf8))
        } catch {
            throw AIError.invalidStructuredOutput("grammar-constrained output was not valid JSON: \(text)")
        }
    }

    public func ensureModel(_: AIEnsureModelRequest) -> AsyncThrowingStream<AIDownloadEvent, any Error> {
        guard let download else {
            return AsyncThrowingStream {
                $0.finish(throwing: AIError.unsupportedPlatform("this backend was constructed with a fixed model path"))
            }
        }
        return download.downloader.events(for: download.spec)
    }

    // MARK: - Helpers

    /// Run a generation to completion, accumulating the emitted pieces.
    private func collect(_ request: AIGenerateRequest, grammar: String?) async throws -> String {
        let box = Accumulator()
        try await engine.run(
            system: request.system,
            prompt: request.prompt,
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            grammar: grammar
        ) { piece in box.append(piece) }
        return box.value
    }
}

/// Thread-safe sink for the `@Sendable` emit callback (the actor may invoke it
/// from its executor; the lock keeps the append race-free and `Sendable`).
private final class Accumulator: @unchecked Sendable {
    private var text = ""
    private let lock = NSLock()
    func append(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        text += s
    }

    var value: String {
        lock.lock(); defer { lock.unlock() }
        return text
    }
}
