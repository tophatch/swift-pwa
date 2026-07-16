import Foundation

/// The Qwen3-TTS model configuration — the structural constants and control
/// token ids parsed from the export's `config.json`. Distinct from
/// `QwenTTSModelSpec` (which names files / tensors and holds sampling defaults)
/// because these values are *data* that travels with the weights.
public struct QwenTTSConfig: Sendable, Codable, Equatable {
    public struct Talker: Sendable, Codable, Equatable {
        public var hidden_size: Int
        public var text_hidden_size: Int
        public var vocab_size: Int
        public var num_hidden_layers: Int
        public var num_attention_heads: Int
        public var num_key_value_heads: Int
        public var head_dim: Int
        public var num_code_groups: Int
        public var codec_eos_token_id: Int
        public var codec_think_id: Int
        public var codec_nothink_id: Int
        public var codec_think_bos_id: Int
        public var codec_think_eos_id: Int
        public var codec_pad_id: Int
        public var codec_bos_id: Int
    }

    public struct CodePredictor: Sendable, Codable, Equatable {
        public var hidden_size: Int
        public var vocab_size: Int
        public var num_hidden_layers: Int
        public var num_key_value_heads: Int
        public var head_dim: Int
    }

    public struct TTS: Sendable, Codable, Equatable {
        public var tts_bos_token_id: Int
        public var tts_eos_token_id: Int
        public var tts_pad_token_id: Int
        public var im_start_token_id: Int
        public var im_end_token_id: Int
    }

    public var talker: Talker
    public var code_predictor: CodePredictor
    public var tts: TTS
    public var language_ids: [String: Int]
    /// speaker → dialect language key, or `false` when not a dialect. Decoded
    /// as an optional string (JSON `false` ⇒ nil).
    public var speaker_dialect: [String: DialectFlag]

    /// A `config.json` field that is either `false` (not a dialect) or a
    /// dialect-language string (e.g. `"sichuan_dialect"`).
    public enum DialectFlag: Sendable, Codable, Equatable {
        case none
        case dialect(String)

        public init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .dialect(s) } else { self = .none }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .none: try c.encode(false)
            case let .dialect(s): try c.encode(s)
            }
        }
    }

    /// Load `config.json` from a model directory.
    public static func load(from url: URL) throws -> QwenTTSConfig {
        try JSONDecoder().decode(QwenTTSConfig.self, from: Data(contentsOf: url))
    }
}

/// File names, tensor I/O names, and generation defaults for the Qwen3-TTS
/// ONNX pipeline. The structural numbers live in `QwenTTSConfig` (from
/// `config.json`); this pins the *contract* the Swift backend and the export
/// share, verified against `elbruno/Qwen3-TTS-12Hz-0.6B-CustomVoice-ONNX`.
///
/// The shipping precision (verified: fp16 talker + fp32 code_predictor + fp32
/// vocoder) is a file-name choice — `talkerDecodeFile` points at the fp16
/// export. Only the **decode** talker graph is used: prefill is a token-by-token
/// warm-up loop through it (the `talker_prefill` graph is redundant — identical
/// weights — and is not shipped).
public struct QwenTTSModelSpec: Sendable {
    // Graph files (relative to the model root).
    public var talkerDecodeFile: String
    public var codePredictorFile: String
    public var vocoderFile: String
    /// Subdirectory (under the model root) holding the `.npy` embedding tables,
    /// `config.json`, and `speaker_ids.json`.
    public var embeddingsSubdir: String
    /// Tokenizer files, relative to the model root.
    public var tokenizerVocabFile: String
    public var tokenizerMergesFile: String
    // Names relative to `embeddingsSubdir`.
    public var configFile: String
    public var speakerIdsFile: String

    // Embedding table files (host-side lookups; not ONNX sessions).
    public var textEmbeddingFile: String
    public var talkerCodecEmbeddingFile: String
    /// `cp_codec_embedding_{i}.npy` for i in 0..<15 — built from this template.
    public var cpCodecEmbeddingTemplate: String
    public var textProjFC1WeightFile: String
    public var textProjFC1BiasFile: String
    public var textProjFC2WeightFile: String
    public var textProjFC2BiasFile: String

    // talker_decode I/O.
    public var talkerInputsEmbedsName: String
    public var talkerAttentionMaskName: String
    public var talkerPositionIdsName: String
    public var talkerPastKeysName: String
    public var talkerPastValuesName: String
    public var talkerLogitsName: String
    public var talkerHiddenStatesName: String
    public var talkerPresentKeysName: String
    public var talkerPresentValuesName: String

    // code_predictor I/O.
    public var cpInputsEmbedsName: String
    public var cpGenerationStepsName: String
    public var cpPastKeysName: String
    public var cpPastValuesName: String
    public var cpLogitsName: String
    public var cpPresentKeysName: String
    public var cpPresentValuesName: String

    // vocoder I/O.
    public var vocoderCodesName: String
    public var vocoderWaveformName: String

    /// Output sample rate of the 12 Hz CustomVoice vocoder.
    public var sampleRate: Int
    /// Safety cap on generated frames (a runaway backstop; a normal utterance
    /// terminates on `codec_eos` well before this).
    public var maxFrames: Int

    // Sampling defaults (match the export's generation_config.json).
    public var temperature: Double
    public var topK: Int
    public var repetitionPenalty: Double
    public var minNewTokens: Int

    public init(
        talkerDecodeFile: String = "talker_decode.fp16.onnx",
        codePredictorFile: String = "code_predictor.onnx",
        vocoderFile: String = "vocoder.onnx",
        embeddingsSubdir: String = "embeddings",
        tokenizerVocabFile: String = "tokenizer/vocab.json",
        tokenizerMergesFile: String = "tokenizer/merges.txt",
        configFile: String = "config.json",
        speakerIdsFile: String = "speaker_ids.json",
        textEmbeddingFile: String = "text_embedding.npy",
        talkerCodecEmbeddingFile: String = "talker_codec_embedding.npy",
        cpCodecEmbeddingTemplate: String = "cp_codec_embedding_%d.npy",
        textProjFC1WeightFile: String = "text_projection_fc1_weight.npy",
        textProjFC1BiasFile: String = "text_projection_fc1_bias.npy",
        textProjFC2WeightFile: String = "text_projection_fc2_weight.npy",
        textProjFC2BiasFile: String = "text_projection_fc2_bias.npy",
        sampleRate: Int = 24000,
        maxFrames: Int = 1024,
        temperature: Double = 0.9,
        topK: Int = 50,
        repetitionPenalty: Double = 1.05,
        minNewTokens: Int = 2
    ) {
        self.talkerDecodeFile = talkerDecodeFile
        self.codePredictorFile = codePredictorFile
        self.vocoderFile = vocoderFile
        self.embeddingsSubdir = embeddingsSubdir
        self.tokenizerVocabFile = tokenizerVocabFile
        self.tokenizerMergesFile = tokenizerMergesFile
        self.configFile = configFile
        self.speakerIdsFile = speakerIdsFile
        self.textEmbeddingFile = textEmbeddingFile
        self.talkerCodecEmbeddingFile = talkerCodecEmbeddingFile
        self.cpCodecEmbeddingTemplate = cpCodecEmbeddingTemplate
        self.textProjFC1WeightFile = textProjFC1WeightFile
        self.textProjFC1BiasFile = textProjFC1BiasFile
        self.textProjFC2WeightFile = textProjFC2WeightFile
        self.textProjFC2BiasFile = textProjFC2BiasFile
        talkerInputsEmbedsName = "inputs_embeds"
        talkerAttentionMaskName = "attention_mask"
        talkerPositionIdsName = "position_ids"
        talkerPastKeysName = "past_keys"
        talkerPastValuesName = "past_values"
        talkerLogitsName = "logits"
        talkerHiddenStatesName = "hidden_states"
        talkerPresentKeysName = "present_keys"
        talkerPresentValuesName = "present_values"
        cpInputsEmbedsName = "inputs_embeds"
        cpGenerationStepsName = "generation_steps"
        cpPastKeysName = "past_keys"
        cpPastValuesName = "past_values"
        cpLogitsName = "logits"
        cpPresentKeysName = "present_keys"
        cpPresentValuesName = "present_values"
        vocoderCodesName = "codes"
        vocoderWaveformName = "waveform"
        self.sampleRate = sampleRate
        self.maxFrames = maxFrames
        self.temperature = temperature
        self.topK = topK
        self.repetitionPenalty = repetitionPenalty
        self.minNewTokens = minNewTokens
    }

    /// The default 12 Hz 0.6B CustomVoice spec (fp16 talker + fp32 cp + fp32
    /// vocoder — the device-verified shipping config).
    public static let customVoice0_6B = QwenTTSModelSpec()
}
