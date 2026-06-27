import CLlama
import Foundation
import SwiftPWACore

/// Global, once-only llama.cpp backend init (registers the Metal / CPU
/// backends). Never torn down — it's process-global, so freeing it while
/// another engine is live would be unsafe. A lazily-initialized global `let`
/// is the thread-safe once primitive.
private let llamaBackendInitOnce: Void = {
    llama_backend_init()
    // llama.cpp logs load/context diagnostics to stderr by default. A library
    // shouldn't spew that into the host app's console — install a callback that
    // surfaces only errors (and their continuations).
    llama_log_set({ level, text, _ in
        guard let text, level.rawValue >= GGML_LOG_LEVEL_ERROR.rawValue else { return }
        // Write via FileHandle rather than `fputs(_, stderr)`: Glibc exposes
        // `stderr` as a mutable global `var`, which Swift 6 strict concurrency
        // rejects inside this `@Sendable` callback (the Darwin overlay doesn't).
        // FileHandle.standardError is the portable, concurrency-safe route.
        FileHandle.standardError.write(Data(String(cString: text).utf8))
    }, nil)
}()

/// Owns the loaded `llama_model` and frees it on teardown. A class (not a raw
/// actor field) so the free runs in its own nonisolated `deinit` — Swift 6
/// forbids touching a non-`Sendable` actor field from the actor's `deinit`.
private final class ModelHandle: @unchecked Sendable {
    let model: OpaquePointer
    init(_ model: OpaquePointer) { self.model = model }
    deinit { llama_model_free(model) }
}

/// Owns the llama.cpp model + per-call context and **serializes** all
/// generation. An `actor` for two reasons: a single `llama_context` cannot be
/// driven by concurrent `llama_decode` calls, and the raw `llama_model` /
/// `llama_context` pointers aren't `Sendable` — actor isolation is what makes
/// `LlamaBackend` safely `Sendable` while holding them.
///
/// The model is loaded once (lazily, on first use) and reused; a fresh
/// `llama_context` is created per generation so KV-cache state never bleeds
/// between unrelated calls. Generation runs token-by-token, invoking `emit`
/// for each decoded piece, which the unary path accumulates and the streaming
/// path forwards as a `delta`.
actor LlamaEngine {
    /// Tuning knobs resolved once at construction.
    struct Config {
        var contextLength: Int32 = 4096
        var batchSize: Int32 = 512
        /// Layers offloaded to the GPU (Metal). 999 = "all" — llama clamps to
        /// the model's layer count. 0 forces CPU (useful for tiny models / CI).
        var gpuLayers: Int32 = 999
        var threads: Int32 = 0 // 0 → llama default (physical cores)
    }

    private let modelPath: String
    private let config: Config
    private var handle: ModelHandle?

    init(modelPath: String, config: Config) {
        self.modelPath = modelPath
        self.config = config
    }

    /// Whether the model file exists on disk (cheap; for `ai.info`).
    nonisolated func modelFileExists() -> Bool {
        FileManager.default.fileExists(atPath: modelPath)
    }

    private func ensureLoaded() throws {
        if handle != nil { return }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw AIError.unavailable("model file not found at \(modelPath)")
        }
        _ = llamaBackendInitOnce
        var params = llama_model_default_params()
        params.n_gpu_layers = config.gpuLayers
        guard let m = llama_model_load_from_file(modelPath, params) else {
            throw AIError.unavailable("failed to load model at \(modelPath)")
        }
        handle = ModelHandle(m)
    }

    /// Run one generation. `grammar` (GBNF) constrains decoding when non-nil
    /// (used by `generateJSON`). `emit` is called with each decoded piece;
    /// the call returns when the model emits an end-of-generation token,
    /// `maxTokens` is reached, or the context fills.
    func run(
        system: String?,
        prompt: String,
        maxTokens: Int?,
        temperature: Double?,
        grammar: String?,
        emit: @Sendable (String) -> Void
    ) throws {
        try ensureLoaded()
        guard let model = handle?.model else { throw AIError.unavailable("model not loaded") }
        let vocab = llama_model_get_vocab(model)

        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(config.contextLength)
        cparams.n_batch = UInt32(config.batchSize)
        guard let ctx = llama_init_from_model(model, cparams) else {
            throw AIError.generationFailed("failed to create context")
        }
        defer { llama_free(ctx) }
        if config.threads > 0 { llama_set_n_threads(ctx, config.threads, config.threads) }

        let formatted = formatPrompt(model: model, system: system, prompt: prompt)
        var tokens = tokenize(vocab: vocab, text: formatted, addSpecial: true)
        guard !tokens.isEmpty else { throw AIError.generationFailed("empty prompt after tokenization") }
        guard tokens.count < Int(config.contextLength) else {
            throw AIError.generationFailed("prompt (\(tokens.count) tokens) exceeds context (\(config.contextLength))")
        }

        // Sampler chain: greedy when deterministic constraints matter (grammar
        // or temperature 0), otherwise temperature + distribution sampling.
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(chain) }
        if let grammar {
            grammar.withCString { g in
                "root".withCString { r in
                    if let gs = llama_sampler_init_grammar(vocab, g, r) {
                        llama_sampler_chain_add(chain, gs)
                    }
                }
            }
        }
        let temp = temperature ?? 0.8
        if temp <= 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.95, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(temp)))
            // Deterministic seed keeps tests reproducible; callers that want
            // variety vary the prompt. A future request field can override.
            llama_sampler_chain_add(chain, llama_sampler_init_dist(0xF00D))
        }

        guard decode(ctx: ctx, tokens: &tokens) else {
            throw AIError.generationFailed("decode failed on prompt")
        }

        let limit = maxTokens ?? 512
        var generated = 0
        while generated < limit {
            let tok = llama_sampler_sample(chain, ctx, -1)
            if llama_vocab_is_eog(vocab, tok) { break }
            emit(piece(vocab: vocab, token: tok))
            generated += 1
            var one = [tok]
            guard decode(ctx: ctx, tokens: &one) else {
                throw AIError.generationFailed("decode failed during generation")
            }
        }
    }

    // MARK: - C helpers

    private func decode(ctx: OpaquePointer, tokens: inout [llama_token]) -> Bool {
        tokens.withUnsafeMutableBufferPointer { buf in
            llama_decode(ctx, llama_batch_get_one(buf.baseAddress, Int32(buf.count))) == 0
        }
    }

    /// Apply the model's built-in chat template (ChatML / Llama / etc.) so
    /// instruct models behave. Falls back to a plain concatenation when the
    /// GGUF carries no template.
    private func formatPrompt(model: OpaquePointer, system: String?, prompt: String) -> String {
        guard let tmpl = llama_model_chat_template(model, nil) else {
            return system.map { "\($0)\n\n\(prompt)" } ?? prompt
        }
        var messages: [(String, String)] = []
        if let system, !system.isEmpty { messages.append(("system", system)) }
        messages.append(("user", prompt))

        // Keep the C strings alive for the duration of the call.
        let cStrings = messages.map { (strdup($0.0), strdup($0.1)) }
        defer { for (r, c) in cStrings { free(r); free(c) } }
        let chat = cStrings.map { llama_chat_message(role: $0.0, content: $0.1) }

        let cap = max(2048, messages.reduce(0) { $0 + $1.1.utf8.count } * 4)
        var buf = [CChar](repeating: 0, count: cap)
        let n = chat.withUnsafeBufferPointer { msgs in
            llama_chat_apply_template(tmpl, msgs.baseAddress, msgs.count, true, &buf, Int32(cap))
        }
        if n <= 0 { return system.map { "\($0)\n\n\(prompt)" } ?? prompt }
        let used = min(Int(n), cap)
        return String(decoding: buf.prefix(used).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func tokenize(vocab: OpaquePointer?, text: String, addSpecial: Bool) -> [llama_token] {
        let byteCount = text.utf8.count
        let cap = Int32(byteCount + 16)
        var tokens = [llama_token](repeating: 0, count: Int(cap))
        let n = text.withCString { cstr in
            llama_tokenize(vocab, cstr, Int32(byteCount), &tokens, cap, addSpecial, true)
        }
        if n < 0 { return [] }
        return Array(tokens.prefix(Int(n)))
    }

    private func piece(vocab: OpaquePointer?, token: llama_token) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = llama_token_to_piece(vocab, token, &buf, 256, 0, false)
        if n <= 0 { return "" }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
