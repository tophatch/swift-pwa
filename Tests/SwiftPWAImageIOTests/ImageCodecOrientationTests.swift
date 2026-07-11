import Foundation
@testable import SwiftPWAImageIO
import Testing
#if canImport(CoreGraphics) && canImport(ImageIO)
    import CoreGraphics
    import ImageIO
#endif

/// Orientation guards for `ImageCodec`. `RawImage`, every decode, and the
/// encoded PNG are all **top-row-first** — row 0 is the visual top.
///
/// These run against whichever codec is active on the build platform — Apple
/// (CoreGraphics/ImageIO) or desktop (stb_image). The **Android** codec runs
/// through the Kotlin JNI RPC and can't execute in a host unit test; its
/// orientation is verified on-device (CritterFacts), and BitmapFactory /
/// `Bitmap.compress` are top-row-first by contract.
///
/// This exists because a Stable-Diffusion output came back **upside down on
/// macOS**: `encodePNG` (and a matching flip in the decode `render`) inverted
/// the image on the mistaken "bitmap memory is bottom-row-first" assumption.
/// The two flips cancelled for decode↔encode round-trips (`resizeRGB`, the LaMa
/// decode→edit→encode path), so it stayed latent until a producer fed a
/// top-down image straight to encode with no decode to cancel it. A round-trip
/// test alone can't catch that (two flips cancel) — so orientation is anchored
/// **absolutely**: `decodeIsTopDown` decodes a PNG *we did not produce* (a
/// hand-authored top-red/bottom-blue image, top-down per the PNG spec), and the
/// round-trip then pins `encodePNG` against that verified decode. On Apple,
/// `encodeIsTopDown` adds a second absolute check via an independent no-flip
/// CGImage read of the encoded bytes (the platform where the bug bit).
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

    /// A 2×2 RGB PNG — **row 0 red, row 1 blue** — authored independently of
    /// `ImageCodec` (hand-rolled via zlib, top-down per the PNG spec). The
    /// absolute reference the decode is judged against.
    private let knownTopRedPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEUlEQVR42mP4z8AARAxg8j8AG/ID/Y4I1K8AAAAASUVORK5CYII="

    @Test("decode is top-down — a known top-red PNG decodes with red at row 0")
    func decodeIsTopDown() async throws {
        let img = try await ImageCodec.decodeRGB(path: nil, dataBase64: knownTopRedPNG, size: nil)
        #expect(img.width == 2 && img.height == 2 && img.channels == 3)
        #expect(img.pixels[0] > 200 && img.pixels[2] < 50) // row 0 red (a flip would put blue here)
        let last = (img.height - 1) * img.width * 3
        #expect(img.pixels[last] < 50 && img.pixels[last + 2] > 200) // last row blue
    }

    @Test("decode↔encode preserve orientation — encode agrees with the verified decode")
    func roundTripPreservesOrientation() async throws {
        let png = try await ImageCodec.encodePNG(twoTone(width: 8, height: 8))
        let out = try await ImageCodec.decodeRGB(path: nil, dataBase64: png.base64EncodedString(), size: nil)
        #expect(out.width == 8 && out.height == 8 && out.channels == 3)
        #expect(out.pixels[0] > 200 && out.pixels[2] < 50) // row 0 red…
        let last = (out.height - 1) * out.width * 3
        #expect(out.pixels[last] < 50 && out.pixels[last + 2] > 200) // …last row blue
    }

    #if canImport(CoreGraphics) && canImport(ImageIO)
        /// Top-left RGB of a PNG, read via a fresh no-flip bitmap `draw` —
        /// independent of `ImageCodec`'s own decode so it can judge the encode.
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

        @Test("encodePNG is top-down — the PNG's top row is the RawImage's top row (Apple, independent read)")
        func encodeIsTopDown() async throws {
            let png = try await ImageCodec.encodePNG(twoTone(width: 8, height: 8))
            let (r, _, b) = try topLeftRGB(ofPNG: png)
            #expect(r > 200 && b < 50) // top is red (the flip bug put blue here)
        }
    #endif
}
