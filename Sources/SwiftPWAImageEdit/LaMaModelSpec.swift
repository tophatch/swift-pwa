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
    /// The square pixel size the graph's `image`/`mask` inputs require. The
    /// big-lama fp32 export has **fixed** `512×512` inputs (confirmed by
    /// graph introspection), so the image + mask are resized to this square
    /// for inference; the model output is then resized back to the source
    /// resolution and composited over the original **only within the masked
    /// region**, so unmasked pixels stay pristine (no global resize loss).
    public var inputSize: Int
    /// The longest side of the **working** resolution. The source image + mask
    /// are decoded and the result composited at most this large (aspect
    /// preserved); the returned image is at that working size, not necessarily
    /// the source's. This bounds memory + (on Android) the base64 payload that
    /// crosses the RPC bridge — a 24-megapixel phone photo composited at full
    /// resolution is ~72 MB of RGB per buffer, which OOMs the JNI RPC. The
    /// model still runs at `inputSize`; this only caps the decode/composite
    /// resolution. `0` means "no cap" (use the source resolution).
    public var maxWorkingSide: Int

    public init(
        imageInputName: String = "image",
        maskInputName: String = "mask",
        outputName: String = "output",
        normalizeImageTo01: Bool = true,
        outputIs0To255: Bool = true,
        maskThreshold: UInt8 = 128,
        inputSize: Int = 512,
        maxWorkingSide: Int = 2048
    ) {
        self.imageInputName = imageInputName
        self.maskInputName = maskInputName
        self.outputName = outputName
        self.normalizeImageTo01 = normalizeImageTo01
        self.outputIs0To255 = outputIs0To255
        self.maskThreshold = maskThreshold
        self.inputSize = inputSize
        self.maxWorkingSide = maxWorkingSide
    }

    /// The big-lama fp32 contract (all defaults) — `image`/`mask`
    /// `[1,C,512,512]` float32, image `[0,1]` RGB, mask `[0,1]` (white =
    /// fill), `output` `[0,255]` RGB.
    public static let bigLama = LaMaModelSpec()

    /// The working `(width, height)` for a source of `(width, height)`: scaled
    /// so the longer side is at most `maxWorkingSide` (aspect preserved), or
    /// the source size unchanged when it already fits (or the cap is `0`).
    func workingSize(forWidth width: Int, height: Int) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard maxWorkingSide > 0, longest > maxWorkingSide else { return (width, height) }
        let scale = Double(maxWorkingSide) / Double(longest)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
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

    /// Canonical big-lama fp32 weights on this repo's stable `lama-vendor`
    /// GitHub Release (Carve's LaMa-ONNX re-export of the Apache-2.0 big-lama
    /// checkpoint, `[1,C,512,512]` I/O). The checksum + size are pinned
    /// against the exact bytes `Scripts/vendor-lama.sh` downloads (which
    /// `.github/workflows/lama-vendor.yml` re-hosts byte-identically).
    ///
    /// > The `lama-vendor` release must be published (run the workflow) before
    /// > `LaMaBackend(cacheDirectory:)`'s `ai.ensureModel` can fetch from this
    /// > URL. Until then, use `LaMaBackend(modelPath:)` with a local export.
    public static let bigLama = LaMaModelSource(
        url: URL(string: "https://github.com/tophatch/swift-pwa/releases/download/lama-vendor/big-lama.onnx")!,
        sha256: "1faef5301d78db7dda502fe59966957ec4b79dd64e16f03ed96913c7a4eb68d6",
        fileName: "big-lama.onnx",
        sizeBytes: 208_044_816
    )
}
