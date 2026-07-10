import Foundation

/// The graph contract of a LaMa-family inpainting ONNX export, and the
/// pre/post-processing knobs that go with it. Deliberately configurable
/// (not hard-coded) because LaMa ONNX exports vary — tensor names,
/// normalization, and output range differ between the common
/// `lama-cleaner` / `iopaint` big-lama export and others. The defaults
/// below match the widely-used **big-lama fp32** export (dynamic `H×W`,
/// `[0,1]` RGB image + `[0,1]` binary mask, `[0,255]` RGB output).
///
/// > These defaults are the *assumed* contract. Like MobileSAM's, they get
/// > confirmed against the real weights on hardware — see
/// > `docs/proposals/image-generation-editing.md`. Only the constants here
/// > should need to move if an export differs; the plumbing in `LaMaBackend`
/// > and `ImageCodec` is model-agnostic.
public struct LaMaModelSpec: Sendable, Equatable {
    /// Graph input name for the RGB image tensor (`[1,3,H,W]` float32).
    public var imageInputName: String
    /// Graph input name for the mask tensor (`[1,1,H,W]` float32).
    public var maskInputName: String
    /// Graph output name for the inpainted RGB tensor (`[1,3,H,W]` float32).
    public var outputName: String
    /// Divide input pixel values (`0…255`) by 255 into `[0,1]` before
    /// feeding the image. Big-lama expects `[0,1]`.
    public var normalizeImageTo01: Bool
    /// The model's output range: `true` if the graph emits `[0,255]`
    /// (big-lama does), `false` if `[0,1]` (then it's scaled up on read).
    public var outputIs0To255: Bool
    /// Mask threshold on `0…255` luminance: at or above → "inpaint here"
    /// (fed as 1.0), below → keep (0.0). Mask convention is white=edit.
    public var maskThreshold: UInt8
    /// Longest working side. The image+mask are resized so the longer side
    /// is at most this, each dimension rounded to a multiple of
    /// `sizeMultiple`; the result comes back at that working resolution.
    /// Caps inference cost/memory on large inputs.
    public var maxWorkingSide: Int
    /// Both working dimensions are rounded to a multiple of this (LaMa
    /// requires `H,W` divisible by 8).
    public var sizeMultiple: Int

    public init(
        imageInputName: String = "image",
        maskInputName: String = "mask",
        outputName: String = "output",
        normalizeImageTo01: Bool = true,
        outputIs0To255: Bool = true,
        maskThreshold: UInt8 = 128,
        maxWorkingSide: Int = 1024,
        sizeMultiple: Int = 8
    ) {
        self.imageInputName = imageInputName
        self.maskInputName = maskInputName
        self.outputName = outputName
        self.normalizeImageTo01 = normalizeImageTo01
        self.outputIs0To255 = outputIs0To255
        self.maskThreshold = maskThreshold
        self.maxWorkingSide = maxWorkingSide
        self.sizeMultiple = sizeMultiple
    }

    /// The assumed big-lama fp32 contract (all defaults).
    public static let bigLama = LaMaModelSpec()

    /// The working `(width, height)` for a source of `(width, height)`:
    /// scaled so the longer side ≤ `maxWorkingSide`, each rounded (down, min
    /// one step) to a multiple of `sizeMultiple`.
    func workingSize(forWidth width: Int, height: Int) -> (width: Int, height: Int) {
        let longest = max(width, height)
        let scale = longest > maxWorkingSide ? Double(maxWorkingSide) / Double(longest) : 1
        func round8(_ value: Double) -> Int {
            max(sizeMultiple, Int((value / Double(sizeMultiple)).rounded()) * sizeMultiple)
        }
        return (round8(Double(width) * scale), round8(Double(height) * scale))
    }
}

/// A downloadable LaMa ONNX model. Mirrors `SwiftPWASegmentation`'s
/// `MobileSAMModelSource` — a URL, a pinned SHA-256, a cache filename, and a
/// byte size (for the `ai.ensureModel` progress bar). The graph must match
/// the accompanying `LaMaModelSpec`.
public struct LaMaModelSource: Sendable, Equatable {
    public let url: URL
    public let sha256: String
    public let fileName: String
    public let sizeBytes: Int64

    public init(url: URL, sha256: String, fileName: String, sizeBytes: Int64) {
        self.url = url
        self.sha256 = sha256
        self.fileName = fileName
        self.sizeBytes = sizeBytes
    }

    /// Canonical big-lama weights on this repo's stable `lama-vendor` GitHub
    /// Release.
    ///
    /// > PENDING: the `lama-vendor` release + its `.github/workflows/lama-
    /// > vendor.yml` publish step are a follow-up (like MobileSAM's
    /// > `mobilesam-vendor`); the `sha256`/`sizeBytes` below are placeholders
    /// > to be pinned against the published asset. Until then, construct
    /// > `LaMaBackend(modelPath:)` with a local export, or pass a custom
    /// > `LaMaModelSource` pointing at your own hosting.
    public static let bigLama = LaMaModelSource(
        url: URL(string: "https://github.com/tophatch/swift-pwa/releases/download/lama-vendor/big-lama.onnx")!,
        sha256: "0000000000000000000000000000000000000000000000000000000000000000",
        fileName: "big-lama.onnx",
        sizeBytes: 0
    )
}
