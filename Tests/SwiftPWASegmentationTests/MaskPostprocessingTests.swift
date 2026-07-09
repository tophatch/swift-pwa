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
}
