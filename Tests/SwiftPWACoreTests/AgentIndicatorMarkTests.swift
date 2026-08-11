import Foundation
#if canImport(ImageIO)
    import ImageIO
#endif
@testable import SwiftPWACore
import Testing

/// The mark is drawn rather than shipped as bytes, so its geometry and the
/// hand-rolled PNG writer both need checking here — there's no image library in
/// Core to lean on, and the platforms where it's hardest to look at it (Windows,
/// Linux) are the ones that can't run these tests.
@Suite("Agent indicator mark")
struct AgentIndicatorMarkTests {
    static let side = AgentIndicatorMark.side

    static func alpha(_ pixels: [UInt8], x: Int, y: Int) -> UInt8 {
        pixels[(y * side + x) * 4 + 3]
    }

    static func luminance(_ pixels: [UInt8], x: Int, y: Int) -> UInt8 {
        pixels[(y * side + x) * 4]
    }

    @Test("waiting is a ring: the centre is empty, the ring is not")
    func waitingIsHollow() {
        let pixels = AgentIndicatorMark.raster(connected: false, lightForeground: false)
        let mid = Self.side / 2
        #expect(Self.alpha(pixels, x: mid, y: mid) == 0, "the centre should be open while waiting")

        // Somewhere on the ring itself — walking out from the centre must cross
        // it, wherever exactly the radius falls.
        let onRing = (0 ..< mid).contains { Self.alpha(pixels, x: mid + $0, y: mid) > 0 }
        #expect(onRing, "no ring found on a row through the centre")
    }

    @Test("connected fills the centre, inset from the ring with a gap between")
    func connectedHasAnInsetDot() {
        let pixels = AgentIndicatorMark.raster(connected: true, lightForeground: false)
        let mid = Self.side / 2
        #expect(Self.alpha(pixels, x: mid, y: mid) == 255, "the centre should be filled once connected")

        // The dot must not touch the ring, or at tray size the two merge into
        // the filled blob this replaced. Walking out from the centre: dot, then
        // a run of empty pixels, then ring.
        var sawGapAfterDot = false
        var leftDot = false
        for dx in 0 ..< mid {
            let a = Self.alpha(pixels, x: mid + dx, y: mid)
            if !leftDot, a == 0 { leftDot = true }
            if leftDot, a == 0 { sawGapAfterDot = true }
            if leftDot, a > 0 { break }
        }
        #expect(sawGapAfterDot, "the dot runs into the ring — no clear gap")
    }

    @Test("the two states are actually different images")
    func statesDiffer() {
        #expect(
            AgentIndicatorMark.png(connected: true, lightForeground: false)
                != AgentIndicatorMark.png(connected: false, lightForeground: false)
        )
    }

    @Test("polarity flips the art's colour, not its shape")
    func polarityOnlyChangesColour() {
        let dark = AgentIndicatorMark.raster(connected: true, lightForeground: false)
        let light = AgentIndicatorMark.raster(connected: true, lightForeground: true)
        let mid = Self.side / 2
        #expect(Self.luminance(dark, x: mid, y: mid) == 0)
        #expect(Self.luminance(light, x: mid, y: mid) == 255)

        // Identical coverage: same mark, different ink.
        let darkAlpha = stride(from: 3, to: dark.count, by: 4).map { dark[$0] }
        let lightAlpha = stride(from: 3, to: light.count, by: 4).map { light[$0] }
        #expect(darkAlpha == lightAlpha)
    }

    @Test("it antialiases rather than drawing hard-edged pixels")
    func edgesAreSmoothed() {
        let pixels = AgentIndicatorMark.raster(connected: false, lightForeground: false)
        let partial = stride(from: 3, to: pixels.count, by: 4)
            .map { pixels[$0] }
            .filter { $0 > 0 && $0 < 255 }
        #expect(!partial.isEmpty, "every pixel is fully on or off — the mark will look jagged")
    }

    // MARK: - The PNG writer

    @Test("the output is a structurally valid PNG")
    func writesAValidPNG() {
        let data = AgentIndicatorMark.png(connected: true, lightForeground: true)
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

        // Walk the chunk list, checking every declared length and CRC. A
        // truncated or mis-CRC'd chunk is exactly what a loader rejects, and the
        // failure on a real platform is a blank tray slot with nothing logged.
        var offset = 8
        var types: [String] = []
        while offset < data.count {
            let length = Int(be32(data, at: offset))
            let typeRange = (offset + 4) ..< (offset + 8)
            let type = String(decoding: data[typeRange], as: UTF8.self)
            let body = data[typeRange.lowerBound ..< (offset + 8 + length)]
            let declared = be32(data, at: offset + 8 + length)
            #expect(PNG.crc32(Data(body)) == declared, "bad CRC on \(type)")
            types.append(type)
            offset += 12 + length
        }
        #expect(offset == data.count, "chunk lengths don't add up to the file size")
        #expect(types == ["IHDR", "IDAT", "IEND"])

        // IHDR: 8-bit RGBA at the declared side.
        #expect(be32(data, at: 16) == UInt32(Self.side))
        #expect(be32(data, at: 20) == UInt32(Self.side))
        #expect(Array(data[24 ..< 29]) == [8, 6, 0, 0, 0])
    }

    @Test("the zlib wrapper is well-formed and the deflate stream inflates")
    func zlibStreamIsReadable() throws {
        let data = AgentIndicatorMark.png(connected: false, lightForeground: false)
        var offset = 8
        var idat = Data()
        while offset < data.count {
            let length = Int(be32(data, at: offset))
            if String(decoding: data[(offset + 4) ..< (offset + 8)], as: UTF8.self) == "IDAT" {
                idat.append(data[(offset + 8) ..< (offset + 8 + length)])
            }
            offset += 12 + length
        }

        // The two-byte zlib header carries its own check: the big-endian pair
        // must be divisible by 31, which is what a reader tests before anything
        // else.
        let header = (UInt32(idat[idat.startIndex]) << 8) | UInt32(idat[idat.startIndex + 1])
        #expect(header % 31 == 0, "zlib header fails its own check value")

        #if canImport(Darwin)
            // Foundation's `.zlib` is raw DEFLATE, so hand it the payload
            // between the header and the Adler-32 trailer.
            let deflate = idat[(idat.startIndex + 2) ..< (idat.endIndex - 4)]
            let inflated = try (Data(deflate) as NSData).decompressed(using: .zlib) as Data
            // One filter byte plus a row of RGBA, per row.
            #expect(inflated.count == Self.side * (Self.side * 4 + 1))
            #expect(inflated[0] == 0, "rows should be written with filter type 0")
            let trailer = be32(idat, at: idat.count - 4)
            #expect(PNG.adler32([UInt8](inflated)) == trailer, "Adler-32 doesn't match the data")
        #endif
    }

    // The one test that proves an independent decoder accepts what we wrote —
    // CRCs, zlib framing, Adler-32 and all. Apple-only because it's the
    // platform with a decoder to hand, but the bytes are identical everywhere.
    #if canImport(ImageIO)
        @Test("a real PNG decoder reads it back, with the pixels we drew")
        func decodesWithTheSystemDecoder() throws {
            let data = AgentIndicatorMark.png(connected: true, lightForeground: true)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == Self.side)
            #expect(image.height == Self.side)

            // Read the centre pixel back: connected art is a filled dot, and
            // `lightForeground` makes it white.
            let context = try #require(CGContext(
                data: nil, width: Self.side, height: Self.side,
                bitsPerComponent: 8, bytesPerRow: Self.side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
            let pixels = try #require(context.data)
            let mid = Self.side / 2
            let centre = pixels.advanced(by: (mid * Self.side + mid) * 4)
                .assumingMemoryBound(to: UInt8.self)
            #expect(centre[3] == 255, "the centre should be opaque once connected")
            #expect(centre[0] == 255, "light art should be white")
        }
    #endif

    private func be32(_ data: Data, at offset: Int) -> UInt32 {
        (0 ..< 4).reduce(UInt32(0)) { $0 << 8 | UInt32(data[data.startIndex + offset + $1]) }
    }
}
