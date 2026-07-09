import Foundation

/// Turns a decoder's mask logits into the `VisionMask` shape the
/// `ai.vision.*` contract returns (source-pixel `bounds` + row-major
/// `rle`). Pure, dependency-free math — testable without any ONNX Runtime
/// involvement, unlike the encoder/decoder calls themselves. The verified
/// real decoder graph (`Acly/MobileSAM`) already upsamples `masks` to
/// `orig_im_size` internally (its own `Resize` nodes), so there is no
/// client-side resampling step here — just thresholding at logit `0`
/// (SAM's convention) and RLE encoding.
enum MaskPostprocessing {
    /// Encodes a row-major binary mask into `bounds` (tight bbox) + `rle`
    /// (row-major run-length over that box, background-first — see
    /// `docs/proposals/segmentation-plugin.md`). Returns `nil` for an
    /// all-background mask (nothing to report).
    static func encodeRLE(_ mask: [Bool], width: Int, height: Int) -> (bounds: [Int], rle: [Int])? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0 ..< height {
            for x in 0 ..< width where mask[y * width + x] {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        var runs: [Int] = []
        var current = false // runs start with a background (false) count, per the contract
        var runLength = 0
        for y in minY ... maxY {
            for x in minX ... maxX {
                let value = mask[y * width + x]
                if value == current {
                    runLength += 1
                } else {
                    runs.append(runLength)
                    current = value
                    runLength = 1
                }
            }
        }
        runs.append(runLength)
        return (bounds: [minX, minY, maxX, maxY], rle: runs)
    }

    /// The inverse of `encodeRLE` — reconstructs a `bounds`-sized binary
    /// mask from its RLE runs. Test-only (round-trip verification); no
    /// production caller needs to decode its own output.
    static func decodeRLE(bounds: [Int], rle: [Int]) -> [Bool] {
        let width = bounds[2] - bounds[0] + 1
        let height = bounds[3] - bounds[1] + 1
        var mask = [Bool](repeating: false, count: width * height)
        var index = 0
        var value = false
        for run in rle {
            if value {
                for offset in 0 ..< run { mask[index + offset] = true }
            }
            index += run
            value.toggle()
        }
        return mask
    }
}
