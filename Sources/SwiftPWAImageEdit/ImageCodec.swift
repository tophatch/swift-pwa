import Foundation

/// A decoded image as tightly-packed 8-bit channels plus its pixel size.
/// `channels` is 3 (RGB, for the source image) or 1 (grayscale, for the
/// mask). Row-major, no padding: `pixels.count == width * height * channels`.
struct RawImage: Equatable {
    var pixels: [UInt8]
    var width: Int
    var height: Int
    var channels: Int
}

enum ImageCodecError: Error, Equatable {
    case decodeFailed(String)
    case encodeFailed(String)
}

/// Decodes an input image / mask into raw pixels and encodes a result back to
/// PNG — the pieces `LaMaBackend` needs that the ONNX Runtime tier itself
/// doesn't provide. Platform-specific, same shape everywhere: Apple uses
/// CoreGraphics/ImageIO (`ImageCodec+Apple.swift`); Linux/Windows use the
/// vendored stb_image / stb_image_write; Android decodes/encodes over the
/// Kotlin `BitmapFactory` RPC. This is deliberately separate from
/// `SwiftPWASegmentation`'s `ImagePreprocessing`, which is SAM-specific
/// (resize-longest-side, HWC `0…255`, and no encode path — segmentation only
/// ever emits RLE).
enum ImageCodec {}
