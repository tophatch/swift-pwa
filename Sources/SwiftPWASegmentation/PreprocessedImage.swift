import Foundation

/// The MobileSAM encoder's raw HWC input tensor plus the geometry needed
/// to map prompt coordinates and interpret `orig_im_size`. Platform-agnostic
/// — built by CoreGraphics/ImageIO on Apple (`ImagePreprocessing.swift`) or
/// by an Android RPC to Kotlin's `BitmapFactory` (`AndroidImagePreprocessing
/// .swift`), same shape either way.
struct PreprocessedImage {
    /// HWC float32, row-major, `resizedHeight * resizedWidth * 3` elements —
    /// raw pixel values `0...255`, not normalized.
    var tensor: [Float]
    /// The source image's original pixel dimensions — what prompt
    /// coordinates and `orig_im_size` are expressed in.
    var originalWidth: Int
    var originalHeight: Int
    /// The resized dimensions actually fed to the encoder (one of these
    /// equals `targetSize`; the other is smaller — no padding is added on
    /// this side, the encoder graph pads internally).
    var resizedWidth: Int
    var resizedHeight: Int
    /// `resizedWidth / originalWidth` (equivalently `resizedHeight /
    /// originalHeight`, aspect ratio is preserved) — the factor prompt
    /// coordinates must be scaled by to land in the encoder's frame.
    var scale: Double

    /// Maps a point in source-image pixels into the resized image's
    /// coordinate space (what the decoder's `point_coords` input expects —
    /// verified empirically against the real decoder graph, no padding
    /// offset needed since the encoder's internal pad is added after this
    /// frame, top-left anchored).
    func mapPoint(x: Double, y: Double) -> (x: Double, y: Double) {
        (x * scale, y * scale)
    }
}

enum ImagePreprocessingError: Error, Equatable {
    case decodeFailed(String)
    case unsupportedColorFormat(String)
}

/// Resizes (and, per-platform, decodes) an image into the encoder's raw HWC
/// input tensor. The longer side is resized to `targetSize` — no padding,
/// normalization, or channel-transpose on this side; the real MobileSAM
/// encoder graph does all three internally (verified against
/// `Acly/MobileSAM` — see `docs/proposals/segmentation-plugin.md`). The
/// static `load` methods are provided per-platform: `ImagePreprocessing.swift`
/// (CoreGraphics/ImageIO) on Apple, `AndroidImagePreprocessing.swift` (an RPC
/// to Kotlin) on Android.
enum ImagePreprocessing {}
