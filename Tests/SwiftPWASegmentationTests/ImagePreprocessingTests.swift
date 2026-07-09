#if canImport(CoreGraphics) && canImport(ImageIO)
    import CoreGraphics
    @testable import SwiftPWASegmentation
    import Testing

    @Suite("ImagePreprocessing")
    struct ImagePreprocessingTests {
        /// A solid-color `width × height` CGImage — enough to check shape
        /// and resize math without needing a real photo.
        private func solidImage(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws -> CGImage {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            for i in 0 ..< (width * height) {
                pixels[i * 4] = r
                pixels[i * 4 + 1] = g
                pixels[i * 4 + 2] = b
                pixels[i * 4 + 3] = 255
            }
            let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            return try #require(context.makeImage())
        }

        @Test("a square image resizes to exactly targetSize, no padding")
        func squareResize() throws {
            let image = try solidImage(width: 20, height: 20, r: 255, g: 0, b: 0)
            let out = try ImagePreprocessing.preprocess(image, targetSize: 32)
            #expect(out.originalWidth == 20)
            #expect(out.originalHeight == 20)
            #expect(out.resizedWidth == 32)
            #expect(out.resizedHeight == 32)
            #expect(out.tensor.count == 32 * 32 * 3)
        }

        @Test("a wide image's height shrinks proportionally, no padding")
        func wideImageResize() throws {
            let image = try solidImage(width: 20, height: 10, r: 0, g: 255, b: 0)
            let out = try ImagePreprocessing.preprocess(image, targetSize: 32)
            #expect(out.resizedWidth == 32) // longer side hits targetSize exactly
            #expect(out.resizedHeight == 16) // 10 * (32/20)
            #expect(out.tensor.count == 32 * 16 * 3)
        }

        @Test("a tall image's width shrinks proportionally, no padding")
        func tallImageResize() throws {
            let image = try solidImage(width: 10, height: 20, r: 0, g: 0, b: 255)
            let out = try ImagePreprocessing.preprocess(image, targetSize: 32)
            #expect(out.resizedHeight == 32)
            #expect(out.resizedWidth == 16)
            #expect(out.tensor.count == 16 * 32 * 3)
        }

        @Test("the tensor is raw HWC pixel values, not normalized")
        func tensorIsRawPixels() throws {
            let image = try solidImage(width: 8, height: 8, r: 200, g: 100, b: 50)
            let out = try ImagePreprocessing.preprocess(image, targetSize: 8)
            #expect(abs(out.tensor[0] - 200) < 0.01)
            #expect(abs(out.tensor[1] - 100) < 0.01)
            #expect(abs(out.tensor[2] - 50) < 0.01)
        }

        @Test("mapPoint scales a source-pixel point by the resize factor")
        func mapPointScales() {
            let preprocessed = PreprocessedImage(
                tensor: [], originalWidth: 100, originalHeight: 50,
                resizedWidth: 64, resizedHeight: 32, scale: 0.64
            )
            let mapped = preprocessed.mapPoint(x: 50, y: 25)
            #expect(abs(mapped.x - 32) < 0.01) // 50 * 0.64
            #expect(abs(mapped.y - 16) < 0.01) // 25 * 0.64
        }
    }
#endif
