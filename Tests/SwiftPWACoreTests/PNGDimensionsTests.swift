import Foundation
@testable import SwiftPWACore
import Testing

/// Reading a PNG's size out of its header, which is how `window.snapshot`
/// (#255) tells the page how big a canvas to make without decoding the image.
@Suite("PNGDimensions")
struct PNGDimensionsTests {
    private func header(width: UInt32, height: UInt32, signature: [UInt8]? = nil) -> Data {
        var data = Data(signature ?? [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x0D])
        data.append(contentsOf: Array("IHDR".utf8))
        data.append(contentsOf: withUnsafeBytes(of: width.bigEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: height.bigEndian, Array.init))
        return data
    }

    @Test("width and height come out big-endian, from a fixed offset")
    func reads() {
        let dims = PNGDimensions.read(header(width: 2560, height: 1600))
        #expect(dims?.width == 2560)
        #expect(dims?.height == 1600)
    }

    /// The whole eight-byte signature, not the four-byte prefix one caller used
    /// to check: `\x89PNG` is followed by a CRLF pair whose job is to catch a
    /// transfer that mangled line endings, and the two numbers this reads are
    /// worthless if the bytes got there that way.
    @Test("a near-miss signature is rejected")
    func rejectsNearMiss() {
        let mangled: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0A, 0x0A, 0x1A, 0x0A] // CRLF collapsed to LF
        #expect(PNGDimensions.read(header(width: 8, height: 8, signature: mangled)) == nil)
    }

    @Test("short, empty and non-PNG data report nil rather than a size")
    func rejectsRubbish() {
        #expect(PNGDimensions.read(Data()) == nil)
        #expect(PNGDimensions.read(Data([0x89, 0x50, 0x4E, 0x47])) == nil)
        #expect(PNGDimensions.read(Data("GIF89a and then some more bytes".utf8)) == nil)
        // A header that decodes to a zero dimension is not a picture.
        #expect(PNGDimensions.read(header(width: 0, height: 16)) == nil)
    }
}
