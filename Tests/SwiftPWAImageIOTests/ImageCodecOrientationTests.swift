#if canImport(CoreGraphics) && canImport(ImageIO)
    import CoreGraphics
    import Foundation
    import ImageIO
    @testable import SwiftPWAImageIO
    import Testing

    /// Orientation guards for the Apple `ImageCodec`. `RawImage`, every decode,
    /// and the encoded PNG are all **top-row-first** — row 0 is the visual top.
    ///
    /// This is the analogue of `SwiftPWASegmentation`'s
    /// `ImagePreprocessingTests.topDownOrientation`, for the codec's encode/decode
    /// rather than the SAM preprocess. It exists because a Stable-Diffusion output
    /// came back **upside down on macOS**: `encodePNG` (and a matching flip in the
    /// decode `render`) inverted the image on the mistaken "bitmap memory is
    /// bottom-row-first" assumption — a data-backed `CGContext` is actually
    /// top-down (a no-flip `draw`/`makeImage` puts buffer row 0 at the visual top).
    /// The two flips cancelled for decode↔encode round-trips (`resizeRGB`, the LaMa
    /// decode→edit→encode path), so it stayed latent until a producer fed a
    /// top-down image straight to encode with no decode to cancel it.
    ///
    /// A round-trip test alone can't catch that (two flips cancel), so
    /// `encodeIsTopDown` reads the encoded PNG's top row via an *independent*
    /// no-flip bitmap read — the absolute check.
    @Suite("ImageCodec orientation")
    struct ImageCodecOrientationTests {
        /// A `width × height` RGB `RawImage`: top half red, bottom half blue.
        /// Orientation-sensitive — a vertical flip swaps which half is row 0.
        private func twoTone(width: Int, height: Int) -> RawImage {
            var px = [UInt8](repeating: 0, count: width * height * 3)
            for y in 0 ..< height {
                let top = y < height / 2
                for x in 0 ..< width {
                    let i = (y * width + x) * 3
                    px[i] = top ? 255 : 0
                    px[i + 1] = 0
                    px[i + 2] = top ? 0 : 255
                }
            }
            return RawImage(pixels: px, width: width, height: height, channels: 3)
        }

        /// Top-left RGB of a PNG, read via a fresh bitmap `draw` with **no flip** —
        /// the orientation `SwiftPWASegmentation`'s `topDownOrientation` verifies as
        /// top-down. Independent of `ImageCodec`'s own decode so it can judge it.
        private func topLeftRGB(ofPNG data: Data) throws -> (r: UInt8, g: UInt8, b: UInt8) {
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let w = image.width, h = image.height
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let ctx = try #require(CGContext(
                data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            return (rgba[0], rgba[1], rgba[2])
        }

        @Test("encodePNG is top-down — the PNG's top row is the RawImage's top row")
        func encodeIsTopDown() async throws {
            let png = try await ImageCodec.encodePNG(twoTone(width: 8, height: 8))
            let (r, _, b) = try topLeftRGB(ofPNG: png)
            // Top is red (the flip bug put blue here).
            #expect(r > 200 && b < 50)
        }

        @Test("decode↔encode preserve orientation (top stays top, bottom stays bottom)")
        func roundTripPreservesOrientation() async throws {
            let png = try await ImageCodec.encodePNG(twoTone(width: 8, height: 8))
            let out = try await ImageCodec.decodeRGB(path: nil, dataBase64: png.base64EncodedString(), size: nil)
            #expect(out.width == 8 && out.height == 8 && out.channels == 3)
            // Row 0 red…
            #expect(out.pixels[0] > 200 && out.pixels[2] < 50)
            // …last row blue.
            let last = (out.height - 1) * out.width * 3
            #expect(out.pixels[last] < 50 && out.pixels[last + 2] > 200)
        }
    }
#endif
