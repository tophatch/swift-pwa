#if canImport(CoreGraphics) && canImport(ImageIO)
    import CoreGraphics
    import Foundation
    import ImageIO

    /// SAM/MobileSAM's fixed preprocessing: resize so the longer side is
    /// `targetSize` (preserving aspect ratio), pad to a `targetSize` ×
    /// `targetSize` square (top-left origin — unpadded region only), then
    /// per-channel normalize with SAM's fixed ImageNet-derived mean/std.
    /// These constants are the encoder's training-time preprocessing, not a
    /// tunable — every SAM/MobileSAM ONNX export expects exactly this.
    struct PreprocessedImage {
        /// NCHW float32, `3 * targetSize * targetSize` elements.
        var tensor: [Float]
        /// The source image's original pixel dimensions — what prompt
        /// coordinates and the final mask are expressed in.
        var originalWidth: Int
        var originalHeight: Int
        /// The resized-but-not-yet-padded dimensions (one of these equals
        /// `targetSize`; the other is smaller). Needed to map between
        /// source-pixel coordinates and the padded `targetSize` square, and
        /// to crop the padding back off the decoder's output mask.
        var resizedWidth: Int
        var resizedHeight: Int

        /// Maps a point in source-image pixels into the padded
        /// `targetSize` square's coordinate space (what the decoder's
        /// `point_coords` input expects).
        func mapPointToPadded(x: Double, y: Double) -> (x: Double, y: Double) {
            let scale = Double(resizedWidth) / Double(originalWidth)
            return (x * scale, y * scale)
        }
    }

    enum ImagePreprocessingError: Error, Equatable {
        case decodeFailed(String)
        case unsupportedColorFormat(String)
    }

    enum ImagePreprocessing {
        /// SAM's encoder normalization constants (RGB order), applied as
        /// `(pixel - mean) / std` per channel, before the pixel values (0–255)
        /// are used — i.e. NOT pre-divided by 255 first, matching the
        /// reference SAM/MobileSAM preprocessing exactly.
        static let mean: (r: Float, g: Float, b: Float) = (123.675, 116.28, 103.53)
        static let std: (r: Float, g: Float, b: Float) = (58.395, 57.12, 57.375)

        /// Loads, resizes, pads, and normalizes an image file into the
        /// encoder's expected `[1, 3, targetSize, targetSize]` tensor.
        static func load(contentsOf url: URL, targetSize: Int = 1024) throws -> PreprocessedImage {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw ImagePreprocessingError.decodeFailed(url.path)
            }
            return try preprocess(cgImage, targetSize: targetSize)
        }

        /// Same as `load(contentsOf:)`, from in-memory image bytes (PNG/JPEG).
        static func load(data: Data, targetSize: Int = 1024) throws -> PreprocessedImage {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw ImagePreprocessingError.decodeFailed("<in-memory image data>")
            }
            return try preprocess(cgImage, targetSize: targetSize)
        }

        static func preprocess(_ cgImage: CGImage, targetSize: Int) throws -> PreprocessedImage {
            let originalWidth = cgImage.width
            let originalHeight = cgImage.height
            guard originalWidth > 0, originalHeight > 0 else {
                throw ImagePreprocessingError.decodeFailed("zero-sized image")
            }

            // Resize so the longer side == targetSize, preserving aspect ratio
            // (SAM's `ResizeLongestSide`).
            let longSide = max(originalWidth, originalHeight)
            let scale = Double(targetSize) / Double(longSide)
            let resizedWidth = max(1, Int((Double(originalWidth) * scale).rounded()))
            let resizedHeight = max(1, Int((Double(originalHeight) * scale).rounded()))

            var rgba = [UInt8](repeating: 0, count: targetSize * targetSize * 4)
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: &rgba, width: targetSize, height: targetSize, bitsPerComponent: 8,
                      bytesPerRow: targetSize * 4,
                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else {
                throw ImagePreprocessingError.unsupportedColorFormat("could not create an RGBA bitmap context")
            }
            // CGContext's logical coordinate system is bottom-left/y-up —
            // without a flip, drawing at y=0 lands at the *last* rows of
            // the pixel buffer, not the first. Flip so the buffer's row 0
            // is the visual top, then draw at y=0 to top-left-anchor the
            // resized image (the padding — if any — lands at the bottom
            // and/or right), matching SAM's padding convention.
            context.translateBy(x: 0, y: CGFloat(targetSize))
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(resizedWidth), height: CGFloat(resizedHeight)))

            var tensor = [Float](repeating: 0, count: 3 * targetSize * targetSize)
            let plane = targetSize * targetSize
            for pixelIndex in 0 ..< plane {
                let base = pixelIndex * 4
                let r = Float(rgba[base])
                let g = Float(rgba[base + 1])
                let b = Float(rgba[base + 2])
                tensor[pixelIndex] = (r - mean.r) / std.r
                tensor[plane + pixelIndex] = (g - mean.g) / std.g
                tensor[2 * plane + pixelIndex] = (b - mean.b) / std.b
            }

            return PreprocessedImage(
                tensor: tensor,
                originalWidth: originalWidth, originalHeight: originalHeight,
                resizedWidth: resizedWidth, resizedHeight: resizedHeight
            )
        }
    }
#endif
