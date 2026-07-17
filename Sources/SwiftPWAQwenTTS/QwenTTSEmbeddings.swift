import Foundation

/// The host-side embedding tables + text projection the Qwen3-TTS pipeline
/// needs outside the ONNX graphs. In the reference these are `nn.Embedding`
/// lookups and a small MLP that run on the host between talker steps; the
/// export ships them as `.npy` tables and weights.
///
/// - `textProj(tokenId)` = `fc2 · silu(fc1 · text_embedding[tokenId] + b1) + b2`
///   → the 1024-d talker-space embedding of a text token (used to build the
///   prefill and the streamed trailing text).
/// - `talkerCodec(id)` = the talker's own codec/speaker embedding table row
///   (codebook-0 tokens, the speaker id, the codec control ids).
/// - `cpCodec(group, id)` = the code-predictor's per-group embedding for
///   codebooks 1-15.
///
/// The giant `text_embedding` table (151936×2048) stays **memory-mapped** and
/// is row-looked-up on demand; the small tables are mapped too. The projection
/// weights (a few MB) are loaded flat. `@unchecked Sendable`: immutable after
/// init, read-only thereafter.
public final class QwenTTSEmbeddings: @unchecked Sendable {
    public let config: QwenTTSConfig
    public let speakerIds: [String: Int]

    private let textEmbedding: QwenNumpyArray
    private let talkerCodecTable: QwenNumpyArray
    private let cpCodecTables: [QwenNumpyArray] // 15 groups
    private let fc1W: [Float], fc1B: [Float]
    private let fc2W: [Float], fc2B: [Float]
    private let textHidden: Int // fc1 in-dim (== text_hidden_size, 2048)
    private let hidden: Int // fc2 out-dim (== talker hidden_size, 1024)

    /// Load every table + the config from a model `directory`, per `spec`'s
    /// file names.
    public init(directory: URL, spec: QwenTTSModelSpec) throws {
        func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
        config = try QwenTTSConfig.load(from: url(spec.configFile))
        speakerIds = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: url(spec.speakerIdsFile)))
        textEmbedding = try QwenNumpyArray(url: url(spec.textEmbeddingFile))
        talkerCodecTable = try QwenNumpyArray(url: url(spec.talkerCodecEmbeddingFile))
        var cp: [QwenNumpyArray] = []
        for i in 0 ..< (config.talker.num_code_groups - 1) {
            try cp.append(QwenNumpyArray(url: url(String(format: spec.cpCodecEmbeddingTemplate, i))))
        }
        cpCodecTables = cp
        fc1W = try QwenNumpyArray(url: url(spec.textProjFC1WeightFile)).flat()
        fc1B = try QwenNumpyArray(url: url(spec.textProjFC1BiasFile)).flat()
        fc2W = try QwenNumpyArray(url: url(spec.textProjFC2WeightFile)).flat()
        fc2B = try QwenNumpyArray(url: url(spec.textProjFC2BiasFile)).flat()
        textHidden = config.talker.text_hidden_size
        hidden = config.talker.hidden_size
    }

    /// Project a text token id into the 1024-d talker space:
    /// `fc2 · silu(fc1 · te + b1) + b2`. `fc1`/`fc2` are row-major `(out, in)`.
    public func textProj(_ tokenId: Int) -> [Float] {
        let te = textEmbedding.row(tokenId) // [textHidden]
        var h = [Float](repeating: 0, count: textHidden)
        for i in 0 ..< textHidden {
            var acc = fc1B[i]
            let base = i * textHidden
            for j in 0 ..< textHidden { acc += fc1W[base + j] * te[j] }
            h[i] = silu(acc)
        }
        var out = [Float](repeating: 0, count: hidden)
        for i in 0 ..< hidden {
            var acc = fc2B[i]
            let base = i * textHidden
            for j in 0 ..< textHidden { acc += fc2W[base + j] * h[j] }
            out[i] = acc
        }
        return out
    }

    /// The talker's codec/speaker embedding for `id` (codebook-0 token, speaker
    /// id, or a codec control id) — a row of `talker_codec_embedding`.
    public func talkerCodec(_ id: Int) -> [Float] { talkerCodecTable.row(id) }

    /// The code-predictor's embedding for codebook `group` (0-based, 0..<15) and
    /// token `id` — a row of `cp_codec_embedding_{group}`.
    public func cpCodec(_ group: Int, _ id: Int) -> [Float] { cpCodecTables[group].row(id) }

    private func silu(_ x: Float) -> Float { x / (1 + Foundation.exp(-x)) }
}

/// Elementwise vector add (`a + b`), a small helper the prefill/decode input
/// assembly uses repeatedly (sum of codebook embeddings + trailing text).
@inlinable
func qwenVectorAdd(_ a: [Float], _ b: [Float]) -> [Float] {
    var out = a
    for i in out.indices { out[i] += b[i] }
    return out
}
