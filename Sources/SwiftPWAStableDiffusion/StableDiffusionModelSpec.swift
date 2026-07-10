import Foundation

/// The graph contract of a Stable-Diffusion ONNX pipeline export, plus the
/// geometry / scheduler / tokenizer knobs the orchestration needs.
/// Deliberately configurable (not hard-coded), like `LaMaModelSpec`: the
/// 🤗 `optimum`/`diffusers` ONNX exports vary in tensor names, latent
/// scaling, and scheduler constants between checkpoints. The defaults below
/// match the common SD-Turbo / SD-1.x diffusers ONNX layout.
///
/// > These defaults are the **assumed** contract. Like MobileSAM's and
/// > LaMa's, the tensor names / scaling / scheduler constants get confirmed
/// > against the real weights on hardware — see
/// > `docs/proposals/stable-diffusion.md`. Only the constants here should
/// > need to move if an export differs; the orchestration in
/// > `StableDiffusionBackend` is model-agnostic.
public struct StableDiffusionModelSpec: Sendable, Equatable {
    // MARK: Text encoder (CLIP)

    /// Text-encoder input tensor: token ids `[1, tokenizerMaxLength]`.
    /// (The standard export types this **int32**; see the note on
    /// integer-tensor support in `StableDiffusionBackend`.)
    public var inputIdsName: String
    /// Text-encoder output used as the UNet's cross-attention context —
    /// `last_hidden_state` `[1, tokenizerMaxLength, embeddingDim]`.
    public var textEmbeddingName: String

    // MARK: UNet (denoiser)

    /// UNet latent input `[1, latentChannels, h, w]` float32.
    public var unetSampleName: String
    /// UNet timestep input `[1]` (the standard export types this **int64**).
    public var unetTimestepName: String
    /// UNet cross-attention context input (the text embedding).
    public var unetEncoderHiddenStatesName: String
    /// UNet predicted-noise output `[1, latentChannels, h, w]`.
    public var unetOutputName: String

    // MARK: VAE decoder

    /// VAE-decoder latent input `[1, latentChannels, h, w]`.
    public var vaeLatentName: String
    /// VAE-decoder image output `[1, 3, H, W]` in `[-1, 1]`.
    public var vaeImageName: String

    // MARK: Geometry

    /// Latent channel count (SD: 4).
    public var latentChannels: Int
    /// Spatial downscale from image to latent (SD VAE: 8, i.e. a 512² image
    /// is a 64² latent).
    public var vaeScaleFactor: Int
    /// Default output width when the request omits one (multiple of
    /// `vaeScaleFactor`).
    public var defaultWidth: Int
    /// Default output height when the request omits one.
    public var defaultHeight: Int
    /// Divisor applied to latents before VAE decode (`diffusers`
    /// `vae_scaling_factor`; SD-1.x/Turbo: 0.18215).
    public var vaeScalingFactor: Double
    /// CLIP text-embedding dimension (SD-1.x/Turbo CLIP ViT-L/14: 768).
    public var embeddingDim: Int

    // MARK: Sampling

    /// Denoising steps used when the request omits one. SD-Turbo is
    /// designed for a single step; leave headroom with a small default.
    public var defaultSteps: Int
    /// Classifier-free guidance scale when the request omits one. SD-Turbo
    /// is guidance-free (0 → single UNet pass per step); a classic SD model
    /// wants ~7.5 with `classifierFreeGuidance = true`.
    public var defaultGuidanceScale: Double
    /// Whether the model uses classifier-free guidance (a negative-prompt
    /// branch, doubling the UNet batch per step). SD-Turbo: false.
    public var classifierFreeGuidance: Bool

    // MARK: Tokenizer

    /// Tokenizer file names inside the model directory.
    public var tokenizerVocabFileName: String
    public var tokenizerMergesFileName: String
    /// Fixed token sequence length (CLIP: 77).
    public var tokenizerMaxLength: Int
    /// `<|startoftext|>` id (CLIP: 49406).
    public var bosTokenID: Int32
    /// `<|endoftext|>` id (CLIP: 49407).
    public var eosTokenID: Int32

    // MARK: Scheduler

    /// The denoising scheduler constants. Assumed from the diffusers
    /// defaults; **confirmed on the real-weights pass** (the scheduler is
    /// the piece most likely to need correction per checkpoint).
    public var scheduler: SchedulerConfig

    /// Minimal scheduler configuration (diffusers `scheduler_config.json`
    /// subset). The concrete `step()` math lives in the backend and is
    /// finalized against real weights.
    public struct SchedulerConfig: Sendable, Equatable {
        public var numTrainTimesteps: Int
        public var betaStart: Double
        public var betaEnd: Double
        /// `"scaled_linear"` (SD default) or `"linear"`.
        public var betaSchedule: String

        public init(
            numTrainTimesteps: Int = 1000,
            betaStart: Double = 0.00085,
            betaEnd: Double = 0.012,
            betaSchedule: String = "scaled_linear"
        ) {
            self.numTrainTimesteps = numTrainTimesteps
            self.betaStart = betaStart
            self.betaEnd = betaEnd
            self.betaSchedule = betaSchedule
        }
    }

    public init(
        inputIdsName: String = "input_ids",
        textEmbeddingName: String = "last_hidden_state",
        unetSampleName: String = "sample",
        unetTimestepName: String = "timestep",
        unetEncoderHiddenStatesName: String = "encoder_hidden_states",
        unetOutputName: String = "out_sample",
        vaeLatentName: String = "latent_sample",
        vaeImageName: String = "sample",
        latentChannels: Int = 4,
        vaeScaleFactor: Int = 8,
        defaultWidth: Int = 512,
        defaultHeight: Int = 512,
        vaeScalingFactor: Double = 0.18215,
        embeddingDim: Int = 768,
        defaultSteps: Int = 1,
        defaultGuidanceScale: Double = 0.0,
        classifierFreeGuidance: Bool = false,
        tokenizerVocabFileName: String = "vocab.json",
        tokenizerMergesFileName: String = "merges.txt",
        tokenizerMaxLength: Int = 77,
        bosTokenID: Int32 = 49406,
        eosTokenID: Int32 = 49407,
        scheduler: SchedulerConfig = SchedulerConfig()
    ) {
        self.inputIdsName = inputIdsName
        self.textEmbeddingName = textEmbeddingName
        self.unetSampleName = unetSampleName
        self.unetTimestepName = unetTimestepName
        self.unetEncoderHiddenStatesName = unetEncoderHiddenStatesName
        self.unetOutputName = unetOutputName
        self.vaeLatentName = vaeLatentName
        self.vaeImageName = vaeImageName
        self.latentChannels = latentChannels
        self.vaeScaleFactor = vaeScaleFactor
        self.defaultWidth = defaultWidth
        self.defaultHeight = defaultHeight
        self.vaeScalingFactor = vaeScalingFactor
        self.embeddingDim = embeddingDim
        self.defaultSteps = defaultSteps
        self.defaultGuidanceScale = defaultGuidanceScale
        self.classifierFreeGuidance = classifierFreeGuidance
        self.tokenizerVocabFileName = tokenizerVocabFileName
        self.tokenizerMergesFileName = tokenizerMergesFileName
        self.tokenizerMaxLength = tokenizerMaxLength
        self.bosTokenID = bosTokenID
        self.eosTokenID = eosTokenID
        self.scheduler = scheduler
    }

    /// The SD-Turbo contract (all defaults) — guidance-free, single-step,
    /// CLIP ViT-L/14 text encoder, 512² output.
    public static let sdTurbo = StableDiffusionModelSpec()

    /// The latent `(width, height)` for an output `(width, height)`.
    func latentSize(forWidth width: Int, height: Int) -> (width: Int, height: Int) {
        (max(1, width / vaeScaleFactor), max(1, height / vaeScaleFactor))
    }
}

/// A downloadable Stable-Diffusion ONNX pipeline: the three graphs plus the
/// two tokenizer files, each with its remote URL, (optional) pinned
/// SHA-256, cache filename, and byte size. Mirrors
/// `MobileSAMModelSource` — a multi-file source backing the
/// `ai.ensureModel` downloadable tier.
public struct StableDiffusionModelSource: Sendable, Equatable {
    /// One downloadable pipeline file.
    public struct File: Sendable, Equatable {
        public let url: URL
        /// Pinned SHA-256 (lowercase hex), or `nil` until pinned. The
        /// canonical source below is unpinned pending the `sd-vendor`
        /// publish + real-weights pass.
        public let sha256: String?
        public let fileName: String
        public let sizeBytes: Int64

        public init(url: URL, sha256: String?, fileName: String, sizeBytes: Int64) {
            self.url = url
            self.sha256 = sha256
            self.fileName = fileName
            self.sizeBytes = sizeBytes
        }
    }

    public let textEncoder: File
    public let unet: File
    public let vaeDecoder: File
    public let tokenizerVocab: File
    public let tokenizerMerges: File

    public init(textEncoder: File, unet: File, vaeDecoder: File, tokenizerVocab: File, tokenizerMerges: File) {
        self.textEncoder = textEncoder
        self.unet = unet
        self.vaeDecoder = vaeDecoder
        self.tokenizerVocab = tokenizerVocab
        self.tokenizerMerges = tokenizerMerges
    }

    /// All five files, in download order (weights first, tiny tokenizer
    /// files last).
    public var files: [File] {
        [textEncoder, unet, vaeDecoder, tokenizerVocab, tokenizerMerges]
    }

    /// **PLACEHOLDER**, pending the real-weights pass. The URLs point at
    /// this repo's future `sd-vendor` GitHub Release (not published yet, so
    /// they 404 today) and the checksums are unpinned. This exists so the
    /// API shape is complete for review; the canonical, checksum-pinned
    /// source lands with the real-weights integration (the LaMa/MobileSAM
    /// pattern: publish `Scripts/vendor-sd.sh` output, then pin here). Until
    /// then, construct a `StableDiffusionBackend(…paths:)` against a local
    /// export.
    public static let sdTurbo = StableDiffusionModelSource(
        textEncoder: File(
            url: vendorURL("text_encoder.onnx"),
            sha256: nil,
            fileName: "text_encoder.onnx",
            sizeBytes: 0
        ),
        unet: File(url: vendorURL("unet.onnx"), sha256: nil, fileName: "unet.onnx", sizeBytes: 0),
        vaeDecoder: File(
            url: vendorURL("vae_decoder.onnx"),
            sha256: nil,
            fileName: "vae_decoder.onnx",
            sizeBytes: 0
        ),
        tokenizerVocab: File(url: vendorURL("vocab.json"), sha256: nil, fileName: "vocab.json", sizeBytes: 0),
        tokenizerMerges: File(url: vendorURL("merges.txt"), sha256: nil, fileName: "merges.txt", sizeBytes: 0)
    )

    private static func vendorURL(_ file: String) -> URL {
        URL(string: "https://github.com/tophatch/swift-pwa/releases/download/sd-vendor/\(file)")!
    }
}
