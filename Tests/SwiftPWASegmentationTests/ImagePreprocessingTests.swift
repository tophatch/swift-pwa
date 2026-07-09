#if canImport(CoreGraphics) && canImport(ImageIO)
    import CoreGraphics
    @testable import SwiftPWASegmentation
    import Testing

    @Suite("ImagePreprocessing")
    struct ImagePreprocessingTests {
        /// A solid-color `width × height` CGImage — enough to check shape,
        /// resize/pad math, and normalization without needing a real photo.
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

        @Test("a square image resizes to exactly targetSize with no padding")
        func squareNoPadding() throws {
            let image = try solidImage(width: 20, height: 20, r: 255, g: 0, b: 0)
            let out = try ImagePreprocessing.preprocess(image, targetSize: 32)
            #expect(out.originalWidth == 20)
            #expect(out.originalHeight == 20)
            #expect(out.resizedWidth == 32)
            #expect(out.resizedHeight == 32)
            #expect(out.tensor.count == 3 * 32 * 32)
        }

        @Test("a wide image pads the shorter (height) dimension")
        func wideImagePadsHeight() throws {
            let image = try solidImage(width: 20, height: 10, r: 0, g: 255, b: 0)
            let out = try ImagePreprocessing.preprocess(image, targetSize: 32)
            #expect(out.resizedWidth == 32) // longer side hits targetSize exactly
            #expect(out.resizedHeight == 16) // 10 * (32/20)
        }

        @Test("a tall image pads the shorter (width) dimension")
        func tallImagePadsWidth() throws {
            let image = try solidImage(width: 10, height: 20, r: 0, g: 0, b: 255)
            let out = try ImagePreprocessing.preprocess(image, targetSize: 32)
            #expect(out.resizedHeight == 32)
            #expect(out.resizedWidth == 16)
        }

        @Test("a pixel in the image region normalizes to (pixel - mean) / std per channel")
        func normalizationMatchesConstants() throws {
            let image = try solidImage(width: 8, height: 8, r: 200, g: 100, b: 50)
            let out = try ImagePreprocessing.preprocess(image, targetSize: 8)
            let plane = 8 * 8
            let expectedR = (Float(200) - ImagePreprocessing.mean.r) / ImagePreprocessing.std.r
            let expectedG = (Float(100) - ImagePreprocessing.mean.g) / ImagePreprocessing.std.g
            let expectedB = (Float(50) - ImagePreprocessing.mean.b) / ImagePreprocessing.std.b
            #expect(abs(out.tensor[0] - expectedR) < 0.01)
            #expect(abs(out.tensor[plane] - expectedG) < 0.01)
            #expect(abs(out.tensor[2 * plane] - expectedB) < 0.01)
        }

        @Test("padded pixels (outside the resized region) are pure black, normalized")
        func paddedRegionIsBlack() throws {
            // A 32-wide, 16-tall resized image inside a 32x32 square pads
            // rows 16...31 with black (0,0,0) — check a pixel deep in the pad.
            let image = try solidImage(width: 20, height: 10, r: 255, g: 255, b: 255)
            let out = try ImagePreprocessing.preprocess(image, targetSize: 32)
            let plane = 32 * 32
            let paddedPixelIndex = 25 * 32 + 5 // row 25 is past resizedHeight (16)
            let expectedBlackR = (Float(0) - ImagePreprocessing.mean.r) / ImagePreprocessing.std.r
            #expect(abs(out.tensor[paddedPixelIndex] - expectedBlackR) < 0.01)
            _ = plane
        }

        @Test("mapPointToPadded scales a source-pixel point by the resize factor")
        func mapPointToPaddedScales() {
            let preprocessed = PreprocessedImage(
                tensor: [], originalWidth: 100, originalHeight: 50, resizedWidth: 64, resizedHeight: 32
            )
            let mapped = preprocessed.mapPointToPadded(x: 50, y: 25)
            #expect(abs(mapped.x - 32) < 0.01) // 50 * (64/100)
            #expect(abs(mapped.y - 16) < 0.01) // 25 * (64/100), same scale both axes
        }
    }
#endif
