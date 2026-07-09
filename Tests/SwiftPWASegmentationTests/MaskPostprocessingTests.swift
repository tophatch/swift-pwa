@testable import SwiftPWASegmentation
import Testing

@Suite("MaskPostprocessing")
struct MaskPostprocessingTests {
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

    // MARK: - Upsampled RLE (automatic mask generation)

    @Test("encodeUpsampledRLE at scale 1 (no downscale) matches a plain encode")
    func upsampledIdentity() throws {
        // A 2x2 true block in a 4x4 working grid, scale 1.0 → source == work.
        let width = 4, height = 4
        var mask = [Bool](repeating: false, count: width * height)
        for y in 1 ... 2 { for x in 1 ... 2 { mask[y * width + x] = true } }
        let upsampled = try #require(MaskPostprocessing.encodeUpsampledRLE(
            workMask: mask, workWidth: width, workHeight: height, workBounds: [1, 1, 2, 2],
            scale: 1.0, sourceWidth: width, sourceHeight: height
        ))
        let plain = try #require(MaskPostprocessing.encodeRLE(mask, width: width, height: height))
        #expect(upsampled.bounds == plain.bounds)
        #expect(upsampled.rle == plain.rle)
    }

    @Test("encodeUpsampledRLE scales a working mask up to source pixels")
    func upsampledScalesUp() throws {
        // A single set pixel at working (1,1) in a 2x2 grid; scale 0.5 means
        // source is 4x4, so that pixel covers the source 2x2 block [2..3, 2..3].
        let mask = [false, false, false, true] // 2x2, only (1,1) set
        let encoded = try #require(MaskPostprocessing.encodeUpsampledRLE(
            workMask: mask, workWidth: 2, workHeight: 2, workBounds: [1, 1, 1, 1],
            scale: 0.5, sourceWidth: 4, sourceHeight: 4
        ))
        // Source bbox: floor(1/0.5)=2 .. ceil(2/0.5)-1=3 in both axes.
        #expect(encoded.bounds == [2, 2, 3, 3])
        // Every source pixel in that 2x2 box maps back to work (1,1) → all set.
        let decoded = MaskPostprocessing.decodeRLE(bounds: encoded.bounds, rle: encoded.rle)
        #expect(decoded == [true, true, true, true])
    }

    @Test("encodeUpsampledRLE returns nil for an all-background mask")
    func upsampledEmpty() {
        let mask = [Bool](repeating: false, count: 4)
        #expect(MaskPostprocessing.encodeUpsampledRLE(
            workMask: mask, workWidth: 2, workHeight: 2, workBounds: [0, 0, 1, 1],
            scale: 0.5, sourceWidth: 4, sourceHeight: 4
        ) == nil)
    }
}
