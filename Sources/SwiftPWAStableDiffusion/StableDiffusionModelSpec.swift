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

    /// Text-encoder input tensor: token ids `[1, tokenizerMaxLength]`. The
    /// optimum ONNX export types this **int64** (confirmed on SD-Turbo — see
    /// `inputIdsInt64`), fed via `OrtInput.int64`.
    public var inputIdsName: String
    /// Text-encoder output used as the UNet's cross-attention context —
    /// `last_hidden_state` `[1, tokenizerMaxLength, embeddingDim]`.
    public var textEmbeddingName: String

    // MARK: UNet (denoiser)

    /// UNet latent input `[1, latentChannels, h, w]` float32.
    public var unetSampleName: String
    /// UNet timestep input. The optimum ONNX export types this a **float32
    /// scalar** (0-dim, confirmed on SD-Turbo — see `timestepIsFloatScalar`),
    /// fed via `OrtInput.float` with an empty shape.
    public var unetTimestepName: String
    /// UNet cross-attention context input (the text embedding).
    public var unetEncoderHiddenStatesName: String
    /// UNet predicted-noise output `[1, latentChannels, h, w]`.
    public var unetOutputName: String
    /// UNet guidance-embedding input (`timestep_cond`), present only on an
    /// **LCM** export — the `[1, guidanceEmbeddingDim]` guidance-scale
    /// embedding that replaces classifier-free guidance. `nil` for a plain SD
    /// / SD-Turbo export (no such input); when set, the loop feeds
    /// `StableDiffusionSampling.guidanceScaleEmbedding` at every step.
    public var unetTimestepCondName: String?
    /// The LCM guidance-embedding width (the UNet's `time_cond_proj_dim`, 256
    /// for `LCM_Dreamshaper_v7`). Used only when `unetTimestepCondName` is set.
    public var guidanceEmbeddingDim: Int

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
    /// Text-embedding dimension. **1024** for SD-Turbo / SD-2.1 (OpenCLIP
    /// ViT-H/14 — confirmed by graph introspection); SD-1.5's CLIP ViT-L/14
    /// is 768. Informational — the graph carries its own output shape.
    public var embeddingDim: Int

    // MARK: Graph dtypes

    /// Feed `input_ids` as int64 (`OrtInput.int64`). The optimum SD export
    /// types the text-encoder token-id input int64; `false` feeds int32 for an
    /// export that differs.
    public var inputIdsInt64: Bool
    /// Feed the UNet `timestep` as a float scalar (`OrtInput.float`/`.float16`,
    /// empty shape). The optimum SD export types it float; `false` feeds an
    /// int64 scalar for an export that differs.
    public var timestepIsFloatScalar: Bool
    /// The model's float tensors are **fp16** (`OrtInput.float16`) rather than
    /// float32 — an `optimum --dtype fp16` export: half the download, faster on
    /// GPU/CoreML, and still runs on the CPU EP. The pipeline stays in float32;
    /// values are converted at the ONNX boundary. Only this flag differs from
    /// `.sdTurbo` (same tensor names / dtypes / scheduler otherwise).
    public var float16IO: Bool

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
    /// Padding id. CLIP pads with `"!"` = **0**, not the end-of-text token
    /// (the text encoder has no attention mask, so the pad value feeds the
    /// model — confirmed on SD-Turbo).
    public var padTokenID: Int32

    // MARK: Scheduler

    /// The denoising scheduler constants. Assumed from the diffusers
    /// defaults; **confirmed on the real-weights pass** (the scheduler is
    /// the piece most likely to need correction per checkpoint).
    public var scheduler: SchedulerConfig

    /// The `EulerDiscreteScheduler` configuration (a diffusers
    /// `scheduler_config.json` subset). Confirmed against SD-Turbo's export;
    /// `EulerDiscreteScheduler` (in this target) consumes it.
    public struct SchedulerConfig: Sendable, Equatable {
        /// Which sampler to build (the scheduler registry) — `.euler`
        /// (SD-Turbo / plain SD) or `.lcm` (Latent Consistency Models).
        public var kind: SchedulerKind
        public var numTrainTimesteps: Int
        public var betaStart: Double
        public var betaEnd: Double
        /// `"scaled_linear"` (SD default) or `"linear"`.
        public var betaSchedule: String
        /// Noise-prediction parameterization. `"epsilon"` (SD-Turbo / SD-1.x /
        /// LCM_Dreamshaper) is implemented; other types throw until added.
        public var predictionType: String
        /// Inference-timestep spacing for Euler: `"trailing"` (SD-Turbo),
        /// `"linspace"`, or `"leading"`. Ignored by LCM (it has its own
        /// origin-schedule selection).
        public var timestepSpacing: String
        /// Offset added to timesteps under `"leading"` spacing (Euler).
        public var stepsOffset: Int

        /// LCM-only knobs (ignored by Euler):
        /// The LCM distillation schedule length the inference timesteps are
        /// sampled from (diffusers `original_inference_steps`, default 50).
        public var originalInferenceSteps: Int
        /// LCM boundary-condition timestep scaling (diffusers default 10).
        public var timestepScaling: Double
        /// LCM boundary-condition data sigma (diffusers default 0.5).
        public var sigmaData: Double

        public init(
            kind: SchedulerKind = .euler,
            numTrainTimesteps: Int = 1000,
            betaStart: Double = 0.00085,
            betaEnd: Double = 0.012,
            betaSchedule: String = "scaled_linear",
            predictionType: String = "epsilon",
            timestepSpacing: String = "trailing",
            stepsOffset: Int = 1,
            originalInferenceSteps: Int = 50,
            timestepScaling: Double = 10,
            sigmaData: Double = 0.5
        ) {
            self.kind = kind
            self.numTrainTimesteps = numTrainTimesteps
            self.betaStart = betaStart
            self.betaEnd = betaEnd
            self.betaSchedule = betaSchedule
            self.predictionType = predictionType
            self.timestepSpacing = timestepSpacing
            self.stepsOffset = stepsOffset
            self.originalInferenceSteps = originalInferenceSteps
            self.timestepScaling = timestepScaling
            self.sigmaData = sigmaData
        }
    }

    public init(
        inputIdsName: String = "input_ids",
        textEmbeddingName: String = "last_hidden_state",
        unetSampleName: String = "sample",
        unetTimestepName: String = "timestep",
        unetEncoderHiddenStatesName: String = "encoder_hidden_states",
        unetOutputName: String = "out_sample",
        unetTimestepCondName: String? = nil,
        guidanceEmbeddingDim: Int = 256,
        vaeLatentName: String = "latent_sample",
        vaeImageName: String = "sample",
        latentChannels: Int = 4,
        vaeScaleFactor: Int = 8,
        defaultWidth: Int = 512,
        defaultHeight: Int = 512,
        vaeScalingFactor: Double = 0.18215,
        embeddingDim: Int = 1024,
        inputIdsInt64: Bool = true,
        timestepIsFloatScalar: Bool = true,
        float16IO: Bool = false,
        defaultSteps: Int = 1,
        defaultGuidanceScale: Double = 0.0,
        classifierFreeGuidance: Bool = false,
        tokenizerVocabFileName: String = "vocab.json",
        tokenizerMergesFileName: String = "merges.txt",
        tokenizerMaxLength: Int = 77,
        bosTokenID: Int32 = 49406,
        eosTokenID: Int32 = 49407,
        padTokenID: Int32 = 0,
        scheduler: SchedulerConfig = SchedulerConfig()
    ) {
        self.inputIdsName = inputIdsName
        self.textEmbeddingName = textEmbeddingName
        self.unetSampleName = unetSampleName
        self.unetTimestepName = unetTimestepName
        self.unetEncoderHiddenStatesName = unetEncoderHiddenStatesName
        self.unetOutputName = unetOutputName
        self.unetTimestepCondName = unetTimestepCondName
        self.guidanceEmbeddingDim = guidanceEmbeddingDim
        self.vaeLatentName = vaeLatentName
        self.vaeImageName = vaeImageName
        self.latentChannels = latentChannels
        self.vaeScaleFactor = vaeScaleFactor
        self.defaultWidth = defaultWidth
        self.defaultHeight = defaultHeight
        self.vaeScalingFactor = vaeScalingFactor
        self.embeddingDim = embeddingDim
        self.inputIdsInt64 = inputIdsInt64
        self.timestepIsFloatScalar = timestepIsFloatScalar
        self.float16IO = float16IO
        self.defaultSteps = defaultSteps
        self.defaultGuidanceScale = defaultGuidanceScale
        self.classifierFreeGuidance = classifierFreeGuidance
        self.tokenizerVocabFileName = tokenizerVocabFileName
        self.tokenizerMergesFileName = tokenizerMergesFileName
        self.tokenizerMaxLength = tokenizerMaxLength
        self.bosTokenID = bosTokenID
        self.eosTokenID = eosTokenID
        self.padTokenID = padTokenID
        self.scheduler = scheduler
    }

    /// The SD-Turbo contract (all defaults) — guidance-free, single-step,
    /// OpenCLIP ViT-H/14 text encoder (1024-dim), 512² output; tensor names,
    /// dtypes, and scaling confirmed against the **optimum fp32** ONNX export.
    public static let sdTurbo = StableDiffusionModelSpec()

    /// SD-Turbo from an **`optimum --dtype fp16`** export — identical contract
    /// to `.sdTurbo` but half-precision float I/O (`float16IO`): ~half the
    /// download (~2.5 GB), faster on GPU/CoreML, still runs on the CPU EP.
    public static let sdTurboFp16 = StableDiffusionModelSpec(float16IO: true)

    /// **LCM (`LCM_Dreamshaper_v7`)** — a Latent Consistency Model on an SD-1.5
    /// base, the commercially-usable (**OpenRAIL-M**) few-step tier (vs
    /// SD-Turbo's non-commercial license). Differs from `.sdTurbo` in: the CLIP
    /// text encoder is ViT-L/14 (**768**-dim), the UNet takes a guidance
    /// embedding on `timestep_cond` (so guidance is baked in — no CFG branch),
    /// the scheduler is `.lcm`, and the default is **4 steps** at guidance ~8.
    /// Contract confirmed against the real weights on the real-weights pass.
    public static let lcmDreamshaper = StableDiffusionModelSpec(
        unetTimestepCondName: "timestep_cond",
        guidanceEmbeddingDim: 256,
        embeddingDim: 768,
        defaultSteps: 4,
        defaultGuidanceScale: 8.0,
        // SD-1.5's CLIP (ViT-L/14) pads with the **end-of-text** token, NOT
        // "!" (id 0) the way SD-2.1's OpenCLIP does — confirmed on the
        // real-weights pass (the pad value feeds the encoder, which has no
        // attention mask, so getting this wrong corrupts the embedding).
        padTokenID: 49407,
        scheduler: SchedulerConfig(kind: .lcm)
    )

    /// `.lcmDreamshaper` from an **`optimum --dtype fp16`** export — identical
    /// contract, half-precision float I/O.
    public static let lcmDreamshaperFp16 = StableDiffusionModelSpec(
        unetTimestepCondName: "timestep_cond",
        guidanceEmbeddingDim: 256,
        embeddingDim: 768,
        float16IO: true,
        defaultSteps: 4,
        defaultGuidanceScale: 8.0,
        padTokenID: 49407, // SD-1.5 CLIP pads with end-of-text (see `.lcmDreamshaper`)
        scheduler: SchedulerConfig(kind: .lcm)
    )

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

    /// The canonical **fp16** SD-Turbo pipeline, published on this repo's
    /// `sd-vendor` GitHub Release (an `optimum --dtype fp16` export of
    /// `stabilityai/sd-turbo`, re-hosted with attribution under the Stability
    /// AI Non-Commercial Community License). Pair with
    /// `StableDiffusionModelSpec.sdTurboFp16`. ~2.5 GB total; the UNet is a
    /// single inline file (no external data). Checksums + sizes are pinned
    /// against the published assets.
    public static let sdTurboFp16 = StableDiffusionModelSource(
        textEncoder: File(
            url: vendorURL("sd-turbo-fp16-text_encoder.onnx"),
            sha256: "1efb4e6220164447b01b46b6c0d8a152bf76a9722faea30d8bb5543bf9b75b60",
            fileName: "text_encoder.onnx",
            sizeBytes: 681_210_842
        ),
        unet: File(
            url: vendorURL("sd-turbo-fp16-unet.onnx"),
            sha256: "49370a1a8123f522eead9bbd67006c044af13120a9d647ac78a0dfd73290a400",
            fileName: "unet.onnx",
            sizeBytes: 1_732_796_415
        ),
        vaeDecoder: File(
            url: vendorURL("sd-turbo-fp16-vae_decoder.onnx"),
            sha256: "8369c29a9ef0c1765efa926a70a744242fa9502eb7ef9eb75d45d0a1b559b05d",
            fileName: "vae_decoder.onnx",
            sizeBytes: 99_093_852
        ),
        tokenizerVocab: File(
            url: vendorURL("sd-turbo-vocab.json"),
            sha256: "e089ad92ba36837a0d31433e555c8f45fe601ab5c221d4f607ded32d9f7a4349",
            fileName: "vocab.json",
            sizeBytes: 1_059_962
        ),
        tokenizerMerges: File(
            url: vendorURL("sd-turbo-merges.txt"),
            sha256: "9fd691f7c8039210e0fced15865466c65820d09b63988b0174bfe25de299051a",
            fileName: "merges.txt",
            sizeBytes: 524_619
        )
    )

    /// The **fp32** SD-Turbo pipeline — **not hosted on GitHub**: its UNet's
    /// external-data file (~3.5 GB) exceeds GitHub's 2 GB per-asset limit, so
    /// the fp32 weights will be hosted elsewhere (e.g. Hugging Face) in a
    /// follow-up. Until then, use `StableDiffusionModelSource.sdTurboFp16`
    /// (hosted) or construct `StableDiffusionBackend(…paths:)` against a local
    /// fp32 export (`optimum-cli export onnx --model stabilityai/sd-turbo`,
    /// pair with `StableDiffusionModelSpec.sdTurbo`). Checksums unpinned.
    public static let sdTurbo = StableDiffusionModelSource(
        textEncoder: File(
            url: vendorURL("sd-turbo-text_encoder.onnx"),
            sha256: nil,
            fileName: "text_encoder.onnx",
            sizeBytes: 0
        ),
        unet: File(url: vendorURL("sd-turbo-unet.onnx"), sha256: nil, fileName: "unet.onnx", sizeBytes: 0),
        vaeDecoder: File(
            url: vendorURL("sd-turbo-vae_decoder.onnx"),
            sha256: nil,
            fileName: "vae_decoder.onnx",
            sizeBytes: 0
        ),
        tokenizerVocab: File(
            url: vendorURL("sd-turbo-vocab.json"),
            sha256: nil,
            fileName: "vocab.json",
            sizeBytes: 1_059_962
        ),
        tokenizerMerges: File(
            url: vendorURL("sd-turbo-merges.txt"),
            sha256: nil,
            fileName: "merges.txt",
            sizeBytes: 524_619
        )
    )

    /// The **fp16 `LCM_Dreamshaper_v7`** pipeline (SD-1.5 base), published on
    /// the `sd-vendor` GitHub Release — an `optimum --dtype fp16` export of
    /// `SimianLuo/LCM_Dreamshaper_v7`, re-hosted under its **OpenRAIL-M**
    /// license (commercially usable, unlike SD-Turbo's non-commercial terms).
    /// Pair with `StableDiffusionModelSpec.lcmDreamshaperFp16`. ~2.0 GB. The
    /// tokenizer files are the same CLIP BPE vocab/merges as SD-Turbo
    /// (byte-identical), so they reuse the `sd-turbo-*` assets. Checksums +
    /// sizes pinned against the published assets; verified end-to-end against
    /// a diffusers reference (see `docs/proposals/stable-diffusion.md`).
    public static let lcmDreamshaperFp16 = StableDiffusionModelSource(
        textEncoder: File(
            url: vendorURL("lcm-dreamshaper-fp16-text_encoder.onnx"),
            sha256: "d2dd4a64b8dccce74e784301b914deecf220407bfbace5c6a00de24c81e921c5",
            fileName: "text_encoder.onnx",
            sizeBytes: 246_343_548
        ),
        unet: File(
            url: vendorURL("lcm-dreamshaper-fp16-unet.onnx"),
            sha256: "46e5f072b67816db9018ac09e319fd6957922cb20d33190aa1074b6c66645300",
            fileName: "unet.onnx",
            sizeBytes: 1_720_180_719
        ),
        vaeDecoder: File(
            url: vendorURL("lcm-dreamshaper-fp16-vae_decoder.onnx"),
            sha256: "6a911c6a99625c1252d3811df6e9a8c1847ad1815dffe1f7de7c951e95ec6fb2",
            fileName: "vae_decoder.onnx",
            sizeBytes: 99_685_146
        ),
        // Same CLIP BPE tokenizer as SD-Turbo (identical bytes) — reuse the assets.
        tokenizerVocab: File(
            url: vendorURL("sd-turbo-vocab.json"),
            sha256: "e089ad92ba36837a0d31433e555c8f45fe601ab5c221d4f607ded32d9f7a4349",
            fileName: "vocab.json",
            sizeBytes: 1_059_962
        ),
        tokenizerMerges: File(
            url: vendorURL("sd-turbo-merges.txt"),
            sha256: "9fd691f7c8039210e0fced15865466c65820d09b63988b0174bfe25de299051a",
            fileName: "merges.txt",
            sizeBytes: 524_619
        )
    )

    private static func vendorURL(_ asset: String) -> URL {
        URL(string: "https://github.com/tophatch/swift-pwa/releases/download/sd-vendor/\(asset)")!
    }
}
