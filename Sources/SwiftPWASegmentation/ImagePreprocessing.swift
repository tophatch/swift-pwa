#if canImport(CoreGraphics) && canImport(ImageIO)
    import CoreGraphics
    import Foundation
    import ImageIO

    /// The Apple `ImagePreprocessing.load` implementation — decodes via
    /// CoreGraphics/ImageIO and resizes so the longer side hits `targetSize`.
    /// See `AndroidImagePreprocessing.swift` for the Android counterpart and
    /// `PreprocessedImage.swift` for the shared contract both produce.
    extension ImagePreprocessing {
        /// Loads and resizes an on-disk image into the encoder's expected
        /// `[height, width, 3]` raw pixel tensor.
        static func load(path: String, targetSize: Int = 1024) async throws -> PreprocessedImage {
            let url = URL(fileURLWithPath: path)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw ImagePreprocessingError.decodeFailed(path)
            }
            return try preprocess(cgImage, targetSize: targetSize)
        }

        /// Same as `load(path:)`, from base64-encoded in-memory image bytes
        /// (PNG/JPEG).
        static func load(dataBase64: String, targetSize: Int = 1024) async throws -> PreprocessedImage {
            guard let data = Data(base64Encoded: dataBase64) else {
                throw ImagePreprocessingError.decodeFailed("<invalid base64 image data>")
            }
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
