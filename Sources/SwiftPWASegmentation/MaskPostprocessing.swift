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

    /// Nearest-neighbor-upsamples a working-resolution binary mask to source
    /// pixels and RLE-encodes it. Used by automatic mask generation, which
    /// discovers masks at a reduced resolution (`scale = workDim / sourceDim`)
    /// for speed, then reports each survivor in the contract's source-pixel
    /// `bounds`/`rle` shape. Only the source bbox implied by `workBounds` is
    /// materialized (not the full source frame), so a single huge mask stays
    /// cheap. Returns `nil` for an all-background mask.
    static func encodeUpsampledRLE(
        workMask: [Bool], workWidth: Int, workHeight: Int, workBounds: [Int],
        scale: Double, sourceWidth: Int, sourceHeight: Int
    ) -> (bounds: [Int], rle: [Int])? {
        guard scale > 0 else { return nil }
        // Source bbox covering the working bbox (inclusive), clamped to frame.
        let sx0 = max(0, Int((Double(workBounds[0]) / scale).rounded(.down)))
        let sy0 = max(0, Int((Double(workBounds[1]) / scale).rounded(.down)))
        let sx1 = min(sourceWidth - 1, Int((Double(workBounds[2] + 1) / scale).rounded(.up)) - 1)
        let sy1 = min(sourceHeight - 1, Int((Double(workBounds[3] + 1) / scale).rounded(.up)) - 1)
        guard sx1 >= sx0, sy1 >= sy0 else { return nil }

        let boxWidth = sx1 - sx0 + 1
        let boxHeight = sy1 - sy0 + 1
        var box = [Bool](repeating: false, count: boxWidth * boxHeight)
        for sy in sy0 ... sy1 {
            let wy = min(workHeight - 1, Int(Double(sy) * scale))
            let workRow = wy * workWidth
            let boxRow = (sy - sy0) * boxWidth
            for sx in sx0 ... sx1 {
                let wx = min(workWidth - 1, Int(Double(sx) * scale))
                if workMask[workRow + wx] { box[boxRow + (sx - sx0)] = true }
            }
        }
        // Re-run the tight-bbox RLE over the cropped box, then shift its bounds
        // back into source coordinates.
        guard let encoded = encodeRLE(box, width: boxWidth, height: boxHeight) else { return nil }
        return (
            bounds: [
                encoded.bounds[0] + sx0,
                encoded.bounds[1] + sy0,
                encoded.bounds[2] + sx0,
                encoded.bounds[3] + sy0
            ],
            rle: encoded.rle
        )
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
