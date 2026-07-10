#if os(Linux) || os(Windows)
    import CStbImage
    import Foundation

    /// The desktop (Linux/Windows) `ImagePreprocessing.load` implementation.
    /// Neither platform has CoreGraphics (Apple) or a `BitmapFactory`-over-RPC
    /// path (Android), so decode goes through the vendored public-domain
    /// stb_image (`CStbImage`) and the resize-longest-side downscale is a
    /// pure-Swift bilinear resample. Produces the same `PreprocessedImage`
    /// contract as the other two backends (see `PreprocessedImage.swift`).
    extension ImagePreprocessing {
        static func load(path: String, targetSize: Int = 1024) async throws -> PreprocessedImage {
            guard let data = FileManager.default.contents(atPath: path) else {
                throw ImagePreprocessingError.decodeFailed(path)
            }
            return try decode(data, targetSize: targetSize, label: path)
        }

        static func load(dataBase64: String, targetSize: Int = 1024) async throws -> PreprocessedImage {
            guard let data = Data(base64Encoded: dataBase64) else {
                throw ImagePreprocessingError.decodeFailed("<invalid base64 image data>")
            }
            return try decode(data, targetSize: targetSize, label: "<in-memory image data>")
        }

        private static func decode(_ data: Data, targetSize: Int, label: String) throws -> PreprocessedImage {
            var width: Int32 = 0
            var height: Int32 = 0
            // stb returns a freshly malloc'd RGB8 buffer (alpha dropped); the
            // returned pointer is independent of `data`'s storage, so it's safe
            // to escape the withUnsafeBytes closure.
            let pixels: UnsafeMutablePointer<UInt8>? = data.withUnsafeBytes { raw in
                swiftpwa_decode_image_rgb(
                    raw.bindMemory(to: UInt8.self).baseAddress, Int32(data.count), &width, &height
                )
            }
            guard let pixels, width > 0, height > 0 else {
                throw ImagePreprocessingError.decodeFailed(label)
            }
            defer { swiftpwa_free_image(pixels) }
            let originalWidth = Int(width)
            let originalHeight = Int(height)
            let source = UnsafeBufferPointer(start: pixels, count: originalWidth * originalHeight * 3)

            // Resize so the longer side == targetSize (SAM's ResizeLongestSide),
            // preserving aspect ratio.
            let scale = Double(targetSize) / Double(max(originalWidth, originalHeight))
            let resizedWidth = max(1, Int((Double(originalWidth) * scale).rounded()))
            let resizedHeight = max(1, Int((Double(originalHeight) * scale).rounded()))

            var tensor = [Float](repeating: 0, count: resizedWidth * resizedHeight * 3)
            let sxScale = Double(originalWidth) / Double(resizedWidth)
            let syScale = Double(originalHeight) / Double(resizedHeight)
            for dy in 0 ..< resizedHeight {
                // Pixel-center mapping (align_corners = false), matching the
                // convention CoreGraphics/BitmapFactory downscales use.
                let syf = (Double(dy) + 0.5) * syScale - 0.5
                let sy0 = max(0, min(originalHeight - 1, Int(syf.rounded(.down))))
                let sy1 = min(originalHeight - 1, sy0 + 1)
                let wy = max(0.0, min(1.0, syf - Double(sy0)))
                for dx in 0 ..< resizedWidth {
                    let sxf = (Double(dx) + 0.5) * sxScale - 0.5
                    let sx0 = max(0, min(originalWidth - 1, Int(sxf.rounded(.down))))
                    let sx1 = min(originalWidth - 1, sx0 + 1)
                    let wx = max(0.0, min(1.0, sxf - Double(sx0)))
                    let row0 = sy0 * originalWidth
                    let row1 = sy1 * originalWidth
                    let out = (dy * resizedWidth + dx) * 3
                    for channel in 0 ..< 3 {
                        let p00 = Double(source[(row0 + sx0) * 3 + channel])
                        let p01 = Double(source[(row0 + sx1) * 3 + channel])
                        let p10 = Double(source[(row1 + sx0) * 3 + channel])
                        let p11 = Double(source[(row1 + sx1) * 3 + channel])
                        let top = p00 + (p01 - p00) * wx
                        let bottom = p10 + (p11 - p10) * wx
                        tensor[out + channel] = Float(top + (bottom - top) * wy)
                    }
                }
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
