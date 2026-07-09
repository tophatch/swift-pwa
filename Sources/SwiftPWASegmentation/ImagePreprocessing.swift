#if canImport(CoreGraphics) && canImport(ImageIO)
    import CoreGraphics
    import Foundation
    import ImageIO

    /// The MobileSAM encoder's actual preprocessing split: this side resizes
    /// so the longer side hits `targetSize` (preserving aspect ratio) and
    /// hands the encoder a raw HWC pixel tensor — no padding, no
    /// normalization, no channel transpose. The verified real encoder graph
    /// (`Acly/MobileSAM` on Hugging Face) bakes all three of those into the
    /// ONNX graph itself (mean/std `Sub`/`Div`, a `Transpose` to CHW, then a
    /// `Pad` to square), so doing them again here would double-apply. Every
    /// SAM/MobileSAM ONNX export in this "encoder does its own preprocessing"
    /// shape expects exactly `[height, width, 3]` float32, values `0...255`,
    /// RGB order.
    struct PreprocessedImage {
        /// HWC float32, row-major, `resizedHeight * resizedWidth * 3`
        /// elements — raw pixel values `0...255`, not normalized.
        var tensor: [Float]
        /// The source image's original pixel dimensions — what prompt
        /// coordinates and `orig_im_size` are expressed in.
        var originalWidth: Int
        var originalHeight: Int
        /// The resized dimensions actually fed to the encoder (one of these
        /// equals `targetSize`; the other is smaller — no padding is added
        /// on this side, the encoder graph pads internally).
        var resizedWidth: Int
        var resizedHeight: Int
        /// `resizedWidth / originalWidth` (equivalently `resizedHeight /
        /// originalHeight`, aspect ratio is preserved) — the factor prompt
        /// coordinates must be scaled by to land in the encoder's frame.
        var scale: Double

        /// Maps a point in source-image pixels into the resized image's
        /// coordinate space (what the decoder's `point_coords` input
        /// expects — verified empirically against the real decoder graph,
        /// no padding offset needed since the encoder's internal pad is
        /// added after this frame, top-left anchored).
        func mapPoint(x: Double, y: Double) -> (x: Double, y: Double) {
            (x * scale, y * scale)
        }
    }

    enum ImagePreprocessingError: Error, Equatable {
        case decodeFailed(String)
        case unsupportedColorFormat(String)
    }

    enum ImagePreprocessing {
        /// Loads and resizes an image file into the encoder's expected
        /// `[height, width, 3]` raw pixel tensor.
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

            // Resize so the longer side == targetSize, preserving aspect
            // ratio (SAM's `ResizeLongestSide`).
            let longSide = max(originalWidth, originalHeight)
            let scale = Double(targetSize) / Double(longSide)
            let resizedWidth = max(1, Int((Double(originalWidth) * scale).rounded()))
            let resizedHeight = max(1, Int((Double(originalHeight) * scale).rounded()))

            var rgba = [UInt8](repeating: 0, count: resizedWidth * resizedHeight * 4)
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: &rgba, width: resizedWidth, height: resizedHeight, bitsPerComponent: 8,
                      bytesPerRow: resizedWidth * 4,
                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else {
                throw ImagePreprocessingError.unsupportedColorFormat("could not create an RGBA bitmap context")
            }
            // CGContext's logical coordinate system is bottom-left/y-up —
            // without a flip, drawing at y=0 lands at the *last* rows of the
            // pixel buffer, not the first. Flip so the buffer's row 0 is the
            // visual top.
            context.translateBy(x: 0, y: CGFloat(resizedHeight))
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(resizedWidth), height: CGFloat(resizedHeight)))

            var tensor = [Float](repeating: 0, count: resizedWidth * resizedHeight * 3)
            for pixelIndex in 0 ..< (resizedWidth * resizedHeight) {
                let rgbaBase = pixelIndex * 4
                let tensorBase = pixelIndex * 3
                tensor[tensorBase] = Float(rgba[rgbaBase])
                tensor[tensorBase + 1] = Float(rgba[rgbaBase + 1])
                tensor[tensorBase + 2] = Float(rgba[rgbaBase + 2])
            }

            return PreprocessedImage(
                tensor: tensor,
                originalWidth: originalWidth, originalHeight: originalHeight,
                resizedWidth: resizedWidth, resizedHeight: resizedHeight,
                scale: scale
            )
        }
    }
#endif
