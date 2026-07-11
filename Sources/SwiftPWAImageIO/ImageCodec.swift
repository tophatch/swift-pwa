import Foundation

/// A decoded image as tightly-packed 8-bit channels plus its pixel size.
/// `channels` is 3 (RGB, for a colour image) or 1 (grayscale, for a mask).
/// Row-major, no padding: `pixels.count == width * height * channels`.
package struct RawImage: Equatable {
    package var pixels: [UInt8]
    package var width: Int
    package var height: Int
    package var channels: Int

    package init(pixels: [UInt8], width: Int, height: Int, channels: Int) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.channels = channels
    }
}

package enum ImageCodecError: Error, Equatable {
    case decodeFailed(String)
    case encodeFailed(String)
}

/// Decodes an input image / mask into raw pixels and encodes a result back to
/// PNG — the pieces the on-device image backends (`LaMaBackend` inpainting,
/// `StableDiffusionBackend` text→image) need that the ONNX Runtime tier itself
/// doesn't provide. A shared, package-internal target so both reuse one
/// implementation. Platform-specific, same shape everywhere: Apple uses
/// CoreGraphics/ImageIO (`ImageCodec+Apple.swift`); Linux/Windows use the
/// vendored stb_image / stb_image_write; Android decodes/encodes over the
/// Kotlin `BitmapFactory` RPC. This is deliberately separate from
/// `SwiftPWASegmentation`'s `ImagePreprocessing`, which is SAM-specific
/// (resize-longest-side, HWC `0…255`, and no encode path — segmentation only
/// ever emits RLE).
package enum ImageCodec {}
