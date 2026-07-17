import Foundation

/// A downloadable Qwen3-TTS model — the file set `QwenTTSBackend(cacheDirectory:
/// source:)` fetches (resumable, checksum-pinned) via `ModelDownloader` /
/// `ai.ensureModel`, the audio analogue of `StableDiffusionModelSource` /
/// `LaMaModelSource`. Each `File` maps a flat GitHub-release **asset** (release
/// asset names can't contain `/`) to the **subdir-qualified local path** the
/// backend reads (graphs at the model root, `embeddings/` + `tokenizer/`
/// subdirs), so a fetch lands directly in the layout the fixed-path init expects.
public struct QwenTTSModelSource: Sendable, Equatable {
    /// One downloadable model file.
    public struct File: Sendable, Equatable {
        /// Where to fetch it (a `qwen-tts-vendor` release asset).
        public let url: URL
        /// Pinned SHA-256 (lowercase hex) of the published asset, or `nil`.
        public let sha256: String?
        /// Local path **relative to the cache directory** (may include a
        /// subdir, e.g. `embeddings/text_embedding.npy`).
        public let fileName: String
        /// Size in bytes, for an aggregate progress bar.
        public let sizeBytes: Int64

        public init(url: URL, sha256: String?, fileName: String, sizeBytes: Int64) {
            self.url = url
            self.sha256 = sha256
            self.fileName = fileName
            self.sizeBytes = sizeBytes
        }
    }

    /// All files, in download order (large weights first, tiny tokenizer /
    /// config files last).
    public let files: [File]

    public init(files: [File]) { self.files = files }

    private static func vendorURL(_ asset: String) -> URL {
        URL(string: "https://github.com/tophatch/swift-pwa/releases/download/qwen-tts-vendor/\(asset)")!
    }

    /// Build a `File` from a release asset name, its local (subdir-qualified)
    /// path, checksum, and size.
    private static func file(_ asset: String, _ fileName: String, _ sha256: String, _ size: Int64) -> File {
        File(url: vendorURL(asset), sha256: sha256, fileName: fileName, sizeBytes: size)
    }

    /// The canonical **12 Hz 0.6B CustomVoice** pipeline published on this
    /// repo's `qwen-tts-vendor` GitHub Release — the shipping precision (fp16
    /// talker + fp32 code-predictor + fp32 vocoder + fp16 text-embedding,
    /// ~2.5 GB). Derived from `elbruno/Qwen3-TTS-12Hz-0.6B-CustomVoice-ONNX`
    /// (Apache-2.0) with the talker + text-embedding converted to fp16; see
    /// `Scripts/vendor-qwen-tts.sh`. Checksums + sizes are pinned against the
    /// published assets. Pair with `QwenTTSModelSpec.customVoice0_6B`.
    ///
    /// > The `qwen-tts-vendor` release must be published (run
    /// > `.github/workflows/qwen-tts-vendor.yml`, or upload the assembled files)
    /// > before these URLs resolve.
    public static let customVoice0_6B = QwenTTSModelSource(files: [
        file(
            "talker_decode.fp16.onnx",
            "talker_decode.fp16.onnx",
            "f8316761b2ae1365730b8ae3832d1b425d07e7fb9d4dec192e2449aa2c2b1229",
            4_574_420
        ),
        file(
            "talker_decode.fp16.onnx.data",
            "talker_decode.fp16.onnx.data",
            "e76a6c69a1d73973d36e4dd3ffdebb35426ad4ceb832480806778c5f7d4d7b9a",
            887_212_032
        ),
        file(
            "code_predictor.onnx",
            "code_predictor.onnx",
            "4e741d1e16ba61ca446b060b16d2da9519b11d18aae5d7bbbfcd273745a38225",
            440_686_845
        ),
        file(
            "vocoder.onnx",
            "vocoder.onnx",
            "4ee20178c7ab322891ce412d92edcfbade2e5e94a8cffe054e17b760fc764e45",
            2_712_067
        ),
        file(
            "vocoder.onnx.data",
            "vocoder.onnx.data",
            "f4cd93d2b48b833a6aaca7d5a3c95dd99853baba565514cb91777e3ce3c4cc8d",
            456_261_632
        ),
        file(
            "text_embedding.npy",
            "embeddings/text_embedding.npy",
            "604a66aba7889619c22704bc5f3279553e40dedadef98da359c8868dd33392bf",
            622_329_984
        ),
        file(
            "talker_codec_embedding.npy",
            "embeddings/talker_codec_embedding.npy",
            "65a94ed3c86cb17e40504a581c746b274a4e56ba200c6f99f383a1bb6274cfbd",
            12_583_040
        ),
        file(
            "cp_codec_embedding_0.npy",
            "embeddings/cp_codec_embedding_0.npy",
            "9b1bd89a06be7fc6eb07e6b03d6d3fdc4762b5d0e0db124d74c608c0638082e3",
            8_388_736
        ),
        file(
            "cp_codec_embedding_1.npy",
            "embeddings/cp_codec_embedding_1.npy",
            "f0d6e187dec6f037980e38911b27016c0531bb34718bb96ccb954366fc495d21",
            8_388_736
        ),
        file(
            "cp_codec_embedding_2.npy",
            "embeddings/cp_codec_embedding_2.npy",
            "5ae15feb83dc7f97e6f939fe98c9dda91c08749c2a69384d71a8414166792825",
            8_388_736
        ),
        file(
            "cp_codec_embedding_3.npy",
            "embeddings/cp_codec_embedding_3.npy",
            "2d740ecfaa6591dcf014570a322192dd022f169bcca80849c41801ff496a866a",
            8_388_736
        ),
        file(
            "cp_codec_embedding_4.npy",
            "embeddings/cp_codec_embedding_4.npy",
            "3b466f7d3213b7a8b29381ee47338a9ac4de30460ac3d2defdaceaa0bab657e2",
            8_388_736
        ),
        file(
            "cp_codec_embedding_5.npy",
            "embeddings/cp_codec_embedding_5.npy",
            "494fde5327423a7462d5e3063dcd8f2ad87de411fe5093c587cf8e56b3ae53df",
            8_388_736
        ),
        file(
            "cp_codec_embedding_6.npy",
            "embeddings/cp_codec_embedding_6.npy",
            "e6d6780db3685caee084edbce3b2517e5fa52b6a077890dff9c14b6638bfb564",
            8_388_736
        ),
        file(
            "cp_codec_embedding_7.npy",
            "embeddings/cp_codec_embedding_7.npy",
            "4d10c51b112e7188062a712e0d664a22dd448cea52ed102e094943c871ec3577",
            8_388_736
        ),
        file(
            "cp_codec_embedding_8.npy",
            "embeddings/cp_codec_embedding_8.npy",
            "3bc9ba51d40d91be04f478d9330363af3d1ac1218144e7bf0c8b920bd4d1832a",
            8_388_736
        ),
        file(
            "cp_codec_embedding_9.npy",
            "embeddings/cp_codec_embedding_9.npy",
            "41add7203fe62f322fa66ad353d5a91f265413a5c711681769d5979e526ced51",
            8_388_736
        ),
        file(
            "cp_codec_embedding_10.npy",
            "embeddings/cp_codec_embedding_10.npy",
            "0e6d1bd968d39d53064bf430a0117cd83d452ee3ecf78dbe2648ad4b783d9091",
            8_388_736
        ),
        file(
            "cp_codec_embedding_11.npy",
            "embeddings/cp_codec_embedding_11.npy",
            "c9a1cb9ed2749c9f94fc29a939afdbb8ec341ba3f734c10b507f82a441a7c20e",
            8_388_736
        ),
        file(
            "cp_codec_embedding_12.npy",
            "embeddings/cp_codec_embedding_12.npy",
            "4cc774bda9a3b868461a36d08cd92370b71e162589598d1796b66fd1bb0520d1",
            8_388_736
        ),
        file(
            "cp_codec_embedding_13.npy",
            "embeddings/cp_codec_embedding_13.npy",
            "bf0454c373ff115501d1642675125146e92d91703442ffdf87a35a7b4fe94919",
            8_388_736
        ),
        file(
            "cp_codec_embedding_14.npy",
            "embeddings/cp_codec_embedding_14.npy",
            "57cb0ce39de77611a7be8f3932debe3a2fa9eba9189e7b3fac890c482ce9a8ba",
            8_388_736
        ),
        file(
            "text_projection_fc1_weight.npy",
            "embeddings/text_projection_fc1_weight.npy",
            "4b39093c0011eca2a955fcd272a7165271e3a37ff0d24ab51d5cfa60925b77af",
            16_777_344
        ),
        file(
            "text_projection_fc1_bias.npy",
            "embeddings/text_projection_fc1_bias.npy",
            "e9a50b7668d089b5fc250f15a61941b97e573e43430587be06c404cbe447c5dc",
            8320
        ),
        file(
            "text_projection_fc2_weight.npy",
            "embeddings/text_projection_fc2_weight.npy",
            "104adb52eabb786a4e26696b323e11a92e4b3568849c04960e907ac44d687b4d",
            8_388_736
        ),
        file(
            "text_projection_fc2_bias.npy",
            "embeddings/text_projection_fc2_bias.npy",
            "e66b17cef017c40c37970d27a626171d9a75ab4729fdab7843f8d1f9e9ce7963",
            4224
        ),
        file(
            "config.json",
            "embeddings/config.json",
            "40623c05e03cf97cb5dc8d2ba84aeb0c8f5649600c91bb56d65b416a804f2f56",
            1447
        ),
        file(
            "speaker_ids.json",
            "embeddings/speaker_ids.json",
            "e6ca4dc700095ca487f6da18b146852a1e4ea3d11f827d654fbb071d91a4c199",
            171
        ),
        file(
            "vocab.json",
            "tokenizer/vocab.json",
            "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910",
            2_776_833
        ),
        file(
            "merges.txt",
            "tokenizer/merges.txt",
            "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5",
            1_671_853
        )
    ])
}
