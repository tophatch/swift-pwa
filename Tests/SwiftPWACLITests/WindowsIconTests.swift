import CStbImage
import Foundation
@testable import SwiftPWACLISupport
import Testing

@Suite("Windows icon resource building")
struct WindowsIconTests {
    /// A minimal but valid PNG header: 8-byte signature + an IHDR chunk
    /// declaring `width`×`height`. Only the bytes `pngDimensions` reads
    /// need to be real.
    private func pngHeader(width: UInt32, height: UInt32) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x0D]) // IHDR length
        data.append(contentsOf: Array("IHDR".utf8))
        withUnsafeBytes(of: width.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: height.bigEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: [0x08, 0x06, 0x00, 0x00, 0x00]) // bit depth, colour type, …
        return data
    }

    @Test("reads width and height from a PNG's IHDR")
    func readsDimensions() {
        let dims = WindowsIcon.pngDimensions(pngHeader(width: 1024, height: 512))
        #expect(dims?.width == 1024)
        #expect(dims?.height == 512)
    }

    @Test("rejects bytes that aren't a PNG")
    func rejectsNonPNG() {
        #expect(WindowsIcon.pngDimensions(Data([0x00, 0x01, 0x02, 0x03])) == nil)
        #expect(WindowsIcon.pngDimensions(Data("GIF89a".utf8)) == nil)
    }

    @Test("group directory has the icon header and a single 14-byte entry")
    func groupDirectoryLayout() {
        let dir = WindowsIcon.groupIconDirectory(pngByteCount: 4096, width: 256, height: 256, iconID: 1)
        #expect(dir.count == 6 + 14) // GRPICONDIR + one GRPICONDIRENTRY
        // idReserved = 0, idType = 1 (icon), idCount = 1 — all little-endian WORDs.
        #expect(Array(dir.prefix(6)) == [0, 0, 1, 0, 1, 0])
    }

    @Test("a 256+ dimension is stored as the byte 0 (the format's ≥256 sentinel)")
    func largeDimensionSentinel() {
        let dir = WindowsIcon.groupIconDirectory(pngByteCount: 10, width: 1024, height: 1024, iconID: 1)
        #expect(dir[6] == 0) // bWidth
        #expect(dir[7] == 0) // bHeight
    }

    @Test("a sub-256 dimension is stored verbatim")
    func smallDimensionVerbatim() {
        let dir = WindowsIcon.groupIconDirectory(pngByteCount: 10, width: 48, height: 32, iconID: 1)
        #expect(dir[6] == 48)
        #expect(dir[7] == 32)
    }

    @Test("the entry's byte count and icon id round-trip")
    func entryFields() {
        let dir = WindowsIcon.groupIconDirectory(pngByteCount: 0x1234, width: 64, height: 64, iconID: 1)
        // dwBytesInRes is a little-endian DWORD at offset 6 + 8 = 14.
        let bytesInRes = dir[14 ..< 18].reversed().reduce(0) { ($0 << 8) | UInt32($1) }
        #expect(bytesInRes == 0x1234)
        // nID is a little-endian WORD at offset 18.
        #expect(dir[18] == 1)
        #expect(dir[19] == 0)
    }

    // MARK: - Multi-size group

    @Test("a multi-image group lists every entry with its own size and id")
    func multiImageDirectory() {
        let images = [
            WindowsIcon.IconImage(width: 256, height: 256, png: Data(count: 900), id: 1),
            WindowsIcon.IconImage(width: 48, height: 48, png: Data(count: 300), id: 2),
            WindowsIcon.IconImage(width: 16, height: 16, png: Data(count: 100), id: 3)
        ]
        let dir = WindowsIcon.groupIconDirectory(images: images)
        // Header count == 3, and 3 × 14-byte entries after the 6-byte header.
        #expect(dir[4] == 3)
        #expect(dir.count == 6 + 3 * 14)
        // Second entry (offset 6 + 14 = 20): 48×48, id 2.
        #expect(dir[20] == 48)
        #expect(dir[20 + 1] == 48)
        #expect(dir[20 + 12] == 2) // nID low byte
        // First entry's 256 dimension collapses to the ≥256 sentinel 0.
        #expect(dir[6] == 0)
        #expect(dir[7] == 0)
    }

    // MARK: - Downscale

    /// Build a tightly-packed RGBA8 buffer from a per-pixel closure.
    private func rgba(_ w: Int, _ h: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let (r, g, b, a) = pixel(x, y)
                let o = (y * w + x) * 4
                out[o] = r; out[o + 1] = g; out[o + 2] = b; out[o + 3] = a
            }
        }
        return out
    }

    @Test("a solid opaque colour survives downscale unchanged")
    func solidColourPreserved() {
        let src = rgba(8, 8) { _, _ in (200, 100, 50, 255) }
        let dst = WindowsIcon.downscaleRGBA(src, srcW: 8, srcH: 8, dstW: 2, dstH: 2)
        #expect(dst.count == 2 * 2 * 4)
        for i in stride(from: 0, to: dst.count, by: 4) {
            #expect(dst[i] == 200)
            #expect(dst[i + 1] == 100)
            #expect(dst[i + 2] == 50)
            #expect(dst[i + 3] == 255)
        }
    }

    @Test("a black/white checkerboard averages to mid-grey")
    func checkerboardAverages() {
        // 2×2 checker → 1×1 should average to ~128.
        let src = rgba(2, 2) { x, y in
            let v: UInt8 = (x + y) % 2 == 0 ? 0 : 255
            return (v, v, v, 255)
        }
        let dst = WindowsIcon.downscaleRGBA(src, srcW: 2, srcH: 2, dstW: 1, dstH: 1)
        #expect(dst[0] == 128) // (0+255+255+0)/4 = 127.5 → rounds to 128
        #expect(dst[3] == 255)
    }

    @Test("premultiplied downscale doesn't dark-fringe a coloured pixel next to transparent black")
    func premultipliedNoFringe() {
        // Half opaque red (RGB kept), half fully-transparent black. Straight
        // averaging would halve the red toward black; premultiplied averaging
        // keeps the visible colour red and just lowers alpha.
        let src = rgba(2, 1) { x, _ in
            x == 0 ? (255, 0, 0, 255) : (0, 0, 0, 0)
        }
        let dst = WindowsIcon.downscaleRGBA(src, srcW: 2, srcH: 1, dstW: 1, dstH: 1)
        #expect(dst[0] == 255) // red stays saturated
        #expect(dst[1] == 0)
        #expect(dst[2] == 0)
        #expect(dst[3] == 128) // alpha is the average of 255 and 0
    }

    /// Encode a tightly-packed RGBA8 buffer to PNG bytes via the vendored stb
    /// (the same encoder the resize path uses on the round-trip out).
    private func encodePNG(_ rgba: [UInt8], _ w: Int, _ h: Int) -> Data {
        var len: Int32 = 0
        let ptr = rgba.withUnsafeBufferPointer { swiftpwa_encode_png_rgba($0.baseAddress, Int32(w), Int32(h), &len) }
        defer { swiftpwa_free_png(ptr) }
        return Data(bytes: ptr!, count: Int(len))
    }

    /// Decode PNG bytes back to (RGBA, w, h) via stb.
    private func decodePNG(_ png: Data) -> (pixels: [UInt8], w: Int, h: Int) {
        var w: Int32 = 0
        var h: Int32 = 0
        let ptr = png.withUnsafeBytes { swiftpwa_decode_image_rgba(
            $0.bindMemory(to: UInt8.self).baseAddress,
            Int32(png.count),
            &w,
            &h
        ) }
        defer { swiftpwa_free_image(ptr) }
        return (Array(UnsafeBufferPointer(start: ptr, count: Int(w) * Int(h) * 4)), Int(w), Int(h))
    }

    @Test("resizePNG down-renders a real PNG to the requested size, preserving colour + alpha")
    func resizePNGRoundTrip() throws {
        // A 64×64 semi-transparent orange source, encoded to real PNG bytes.
        let src = rgba(64, 64) { _, _ in (255, 128, 0, 200) }
        let srcPNG = encodePNG(src, 64, 64)

        let out = try #require(WindowsIcon.resizePNG(srcPNG, to: 16))
        let (px, w, h) = decodePNG(out)
        #expect(w == 16)
        #expect(h == 16)
        /// A flat colour survives the box filter within rounding tolerance.
        func near(_ a: UInt8, _ b: UInt8) -> Bool { abs(Int(a) - Int(b)) <= 1 }
        #expect(near(px[0], 255))
        #expect(near(px[1], 128))
        #expect(near(px[2], 0))
        #expect(near(px[3], 200)) // alpha carried through — not flattened to opaque
    }

    @Test("buildImages produces the source plus a rendered image per smaller size")
    func buildImagesMultiSize() {
        // A 128×128 source: smaller than 256 (dropped) but larger than 48/32/16.
        let src = rgba(128, 128) { _, _ in (10, 200, 90, 255) }
        let srcPNG = encodePNG(src, 128, 128)
        let images = WindowsIcon.buildImages(source: srcPNG, width: 128, height: 128)
        // Source verbatim (128) + 48 + 32 + 16.
        #expect(images.map(\.width) == [128, 48, 32, 16])
        #expect(images.map(\.id) == [1, 2, 3, 4])
        #expect(images[0].png == srcPNG) // largest slot is the source, unmodified
    }

    @Test("buildImages returns just the source when no smaller sizes fit")
    func buildImagesSmallSource() {
        // A 12×12 source is smaller than every rendered size (16/32/48/256),
        // so only the verbatim source image comes back.
        let png = pngHeader(width: 12, height: 12)
        let images = WindowsIcon.buildImages(source: png, width: 12, height: 12)
        #expect(images.count == 1)
        #expect(images[0].width == 12)
        #expect(images[0].id == 1)
        #expect(images[0].png == png)
    }
}
