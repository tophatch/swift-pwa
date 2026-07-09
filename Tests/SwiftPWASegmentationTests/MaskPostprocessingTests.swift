@testable import SwiftPWASegmentation
import Testing

@Suite("MaskPostprocessing")
struct MaskPostprocessingTests {
    // MARK: - resize

    @Test("resize is a no-op identity when srcRect covers the whole grid and sizes match")
    func resizeIdentity() {
        let src: [Float] = [1, 2, 3, 4] // 2x2
        let out = MaskPostprocessing.resize(
            src, srcWidth: 2, srcHeight: 2, srcRect: (0, 0, 2, 2), dstWidth: 2, dstHeight: 2
        )
        // Bilinear resample at matching resolution reproduces the source
        // exactly at pixel centers.
        for (a, b) in zip(out, src) {
            #expect(abs(a - b) < 0.0001)
        }
    }

    @Test("resize upsamples a uniform grid to a uniform grid")
    func resizeUniform() {
        let src: [Float] = [5, 5, 5, 5]
        let out = MaskPostprocessing.resize(
            src, srcWidth: 2, srcHeight: 2, srcRect: (0, 0, 2, 2), dstWidth: 8, dstHeight: 8
        )
        #expect(out.allSatisfy { abs($0 - 5) < 0.0001 })
    }

    @Test("resize interpolates a linear ramp")
    func resizeRamp() {
        // A 1-row ramp 0...3 across 4 columns, upsampled to 8 columns should
        // stay monotonically increasing and bounded by the source range.
        let src: [Float] = [0, 1, 2, 3]
        let out = MaskPostprocessing.resize(
            src, srcWidth: 4, srcHeight: 1, srcRect: (0, 0, 4, 1), dstWidth: 8, dstHeight: 1
        )
        #expect(out.count == 8)
        for value in out {
            #expect(value >= -0.5 && value <= 3.5)
        }
        for i in 1 ..< out.count {
            #expect(out[i] >= out[i - 1] - 0.0001)
        }
    }

    @Test("resize honors a cropped srcRect (only the sub-region is sampled)")
    func resizeCropped() {
        // 4x4 grid: columns 0-1 = 0, columns 2-3 = 10.
        var src = [Float](repeating: 0, count: 16)
        for y in 0 ..< 4 {
            for x in 2 ..< 4 { src[y * 4 + x] = 10 }
        }
        // Crop to x in [0, 1) — a full pixel of margin from the value-10
        // region at column 2, so even bilinear sampling right at the crop's
        // edge only ever blends columns 0/1 (both 0), with no edge bleed
        // from the excluded region.
        let out = MaskPostprocessing.resize(
            src, srcWidth: 4, srcHeight: 4, srcRect: (0, 0, 1, 4), dstWidth: 4, dstHeight: 4
        )
        #expect(out.allSatisfy { abs($0) < 0.0001 })
    }

    // MARK: - toSourceMask

    @Test("toSourceMask thresholds at 0 and matches source image dimensions")
    func toSourceMaskShape() {
        let lowResSize = 4
        let targetSize = 16 // gridScale = 4/16 = 0.25
        // All-positive logits → an all-true mask.
        let lowRes = [Float](repeating: 1, count: lowResSize * lowResSize)
        let preprocessed = PreprocessedImage(
            tensor: [], originalWidth: 10, originalHeight: 6, resizedWidth: 16, resizedHeight: 10
        )
        let mask = MaskPostprocessing.toSourceMask(
            lowRes: lowRes, lowResSize: lowResSize, preprocessed: preprocessed, targetSize: targetSize
        )
        #expect(mask.count == preprocessed.originalWidth * preprocessed.originalHeight)
        #expect(!mask.contains(false))
    }

    @Test("toSourceMask an all-negative grid produces an all-false mask")
    func toSourceMaskAllBackground() {
        let lowRes = [Float](repeating: -1, count: 16)
        let preprocessed = PreprocessedImage(
            tensor: [], originalWidth: 8, originalHeight: 8, resizedWidth: 16, resizedHeight: 16
        )
        let mask = MaskPostprocessing.toSourceMask(
            lowRes: lowRes, lowResSize: 4, preprocessed: preprocessed, targetSize: 16
        )
        #expect(mask.allSatisfy { !$0 })
    }

    // MARK: - RLE encode / decode

    @Test("encodeRLE returns nil for an all-background mask")
    func encodeRLEEmpty() {
        let mask = [Bool](repeating: false, count: 9)
        #expect(MaskPostprocessing.encodeRLE(mask, width: 3, height: 3) == nil)
    }

    @Test("encodeRLE + decodeRLE round-trips a simple mask")
    func encodeDecodeRoundTrip() throws {
        // 4x3 mask with a 2x2 true block in the middle.
        let width = 4, height = 3
        var mask = [Bool](repeating: false, count: width * height)
        mask[1 * width + 1] = true
        mask[1 * width + 2] = true
        mask[2 * width + 1] = true
        mask[2 * width + 2] = true

        let encoded = try #require(MaskPostprocessing.encodeRLE(mask, width: width, height: height))
        #expect(encoded.bounds == [1, 1, 2, 2]) // tight bbox around the true block

        let decoded = MaskPostprocessing.decodeRLE(bounds: encoded.bounds, rle: encoded.rle)
        #expect(decoded == [true, true, true, true]) // the whole 2x2 box is foreground
    }

    @Test("encodeRLE + decodeRLE round-trips an irregular mask")
    func encodeDecodeIrregular() throws {
        let width = 5, height = 4
        // A checkerboard-ish pattern, deliberately irregular.
        let flat: [Bool] = [
            false, true, false, false, true,
            true, true, false, true, false,
            false, false, false, true, true,
            true, false, false, false, false
        ]
        let encoded = try #require(MaskPostprocessing.encodeRLE(flat, width: width, height: height))
        let decoded = MaskPostprocessing.decodeRLE(bounds: encoded.bounds, rle: encoded.rle)

        // Reconstruct the full-size mask from the cropped decode to compare.
        let (minX, minY, maxX, maxY) = (encoded.bounds[0], encoded.bounds[1], encoded.bounds[2], encoded.bounds[3])
        let boxWidth = maxX - minX + 1
        for y in minY ... maxY {
            for x in minX ... maxX {
                let original = flat[y * width + x]
                let reconstructed = decoded[(y - minY) * boxWidth + (x - minX)]
                #expect(original == reconstructed)
            }
        }
    }

    @Test("encodeRLE background-first convention: first run count is background pixels")
    func encodeRLEBackgroundFirst() throws {
        // A mask that's true everywhere in its bbox — first run should be 0
        // (zero background pixels before the first foreground pixel).
        let mask = [true, true, true, true]
        let encoded = try #require(MaskPostprocessing.encodeRLE(mask, width: 2, height: 2))
        #expect(encoded.rle.first == 0)
        #expect(encoded.rle.reduce(0, +) == 4)
    }
}
