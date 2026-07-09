import Foundation

/// Turns a decoder's low-resolution mask logits into the `VisionMask` shape
/// the `ai.vision.*` contract returns (source-pixel `bounds` + row-major
/// `rle`). Pure, dependency-free math — testable without any ONNX Runtime
/// involvement, unlike the encoder/decoder calls themselves.
enum MaskPostprocessing {
    /// Bilinearly resamples a row-major float grid. `srcRect` (in the
    /// source grid's own coordinate units, fractional allowed) is the
    /// region resampled into the full `dstWidth × dstHeight` output — this
    /// folds SAM's two-step "upsample to the padded square, then crop off
    /// the padding, then upsample to the original size" into one resample,
    /// by resampling directly from the low-res grid's unpadded sub-rect.
    static func resize(
        _ src: [Float], srcWidth: Int, srcHeight: Int,
        srcRect: (x: Double, y: Double, width: Double, height: Double),
        dstWidth: Int, dstHeight: Int
    ) -> [Float] {
        guard dstWidth > 0, dstHeight > 0 else { return [] }
        var dst = [Float](repeating: 0, count: dstWidth * dstHeight)
        guard srcWidth > 0, srcHeight > 0, srcRect.width > 0, srcRect.height > 0 else { return dst }

        for dy in 0 ..< dstHeight {
            // Sample at the destination pixel's center, mapped into srcRect.
            let v = srcRect.y + (Double(dy) + 0.5) / Double(dstHeight) * srcRect.height
            for dx in 0 ..< dstWidth {
                let u = srcRect.x + (Double(dx) + 0.5) / Double(dstWidth) * srcRect.width
                dst[dy * dstWidth + dx] = bilinearSample(src, width: srcWidth, height: srcHeight, x: u, y: v)
            }
        }
        return dst
    }

    private static func bilinearSample(_ src: [Float], width: Int, height: Int, x: Double, y: Double) -> Float {
        // Sample at the pixel center convention (`pixel[i]` covers
        // `[i, i+1)`), so a source-space coordinate of `x` reads
        // `pixel[x - 0.5]`.
        let fx = x - 0.5
        let fy = y - 0.5
        let x0 = Int(fx.rounded(.down))
        let y0 = Int(fy.rounded(.down))
        let tx = Float(fx - Double(x0))
        let ty = Float(fy - Double(y0))

        func clamp(_ v: Int, _ maxValue: Int) -> Int { min(max(v, 0), maxValue) }
        let x0c = clamp(x0, width - 1), x1c = clamp(x0 + 1, width - 1)
        let y0c = clamp(y0, height - 1), y1c = clamp(y0 + 1, height - 1)

        let topLeft = src[y0c * width + x0c]
        let topRight = src[y0c * width + x1c]
        let bottomLeft = src[y1c * width + x0c]
        let bottomRight = src[y1c * width + x1c]

        let top = topLeft + (topRight - topLeft) * tx
        let bottom = bottomLeft + (bottomRight - bottomLeft) * tx
        return top + (bottom - top) * ty
    }

    /// Upsamples a decoder's low-res mask logits (covering the padded
    /// `targetSize × targetSize` square at `lowResSize × lowResSize`
    /// resolution) directly to a binary mask at the original source-image
    /// dimensions, thresholding at logit `0` (SAM's convention — the
    /// decoder outputs raw logits, not probabilities).
    static func toSourceMask(
        lowRes: [Float], lowResSize: Int, preprocessed: PreprocessedImage, targetSize: Int
    ) -> [Bool] {
        let gridScale = Double(lowResSize) / Double(targetSize)
        let srcRect = (
            x: 0.0, y: 0.0,
            width: Double(preprocessed.resizedWidth) * gridScale,
            height: Double(preprocessed.resizedHeight) * gridScale
        )
        let resized = resize(
            lowRes, srcWidth: lowResSize, srcHeight: lowResSize, srcRect: srcRect,
            dstWidth: preprocessed.originalWidth, dstHeight: preprocessed.originalHeight
        )
        return resized.map { $0 > 0 }
    }

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
