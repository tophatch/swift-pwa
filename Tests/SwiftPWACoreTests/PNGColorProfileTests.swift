import Foundation
@testable import SwiftPWACore
import Testing

/// Splicing a capture's colour profile onto a scaled capture that lost it
/// (#344, WebView2). Built from hand-made chunks: what matters is where the
/// bytes land, not what the image shows.
@Suite("PNGColorProfile")
struct PNGColorProfileTests {
    private let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// A chunk with a fake CRC: nothing here checks it, and the real chunk is
    /// copied with its own.
    private func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let n = UInt32(payload.count)
        return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
            + Array(type.utf8) + payload + [0xDE, 0xAD, 0xBE, 0xEF]
    }

    private func png(_ chunks: [[UInt8]]) -> Data {
        Data(signature + chunks.flatMap(\.self))
    }

    @Test("the profile chunk comes out whole and goes in after IHDR")
    func moves() throws {
        let header = chunk("IHDR", Array(repeating: 1, count: 13))
        let profile = chunk("iCCP", Array("display\0".utf8) + [0, 0x78, 0x9C, 1, 2, 3])
        let data = chunk("IDAT", [9, 9, 9])
        let end = chunk("IEND", [])

        let withProfile = png([header, profile, data, end])
        let lost = png([header, data, end])
        let extracted = try #require(PNGColorProfile.profileChunk(in: withProfile))
        #expect([UInt8](extracted) == profile)
        #expect(PNGColorProfile.profileChunk(in: lost) == nil)

        let restored = PNGColorProfile.inserting(extracted, into: lost)
        #expect(restored == withProfile)
    }

    @Test("an image that already declares a colour space, or isn't a PNG, is left alone")
    func leavesAlone() {
        let header = chunk("IHDR", Array(repeating: 1, count: 13))
        let profile = chunk("iCCP", [1, 2, 3])
        let end = chunk("IEND", [])
        let srgb = png([header, chunk("sRGB", [0]), end])
        #expect(PNGColorProfile.inserting(Data(profile), into: srgb) == srgb)
        let profiled = png([header, profile, end])
        #expect(PNGColorProfile.inserting(Data(profile), into: profiled) == profiled)
        let notPNG = Data("not a png at all".utf8)
        #expect(PNGColorProfile.inserting(Data(profile), into: notPNG) == notPNG)
        #expect(PNGColorProfile.profileChunk(in: notPNG) == nil)
        // A chunk that claims more bytes than there are is a malformed PNG.
        let truncated = Data(signature + [0, 0, 0x10, 0] + Array("IHDR".utf8))
        #expect(PNGColorProfile.profileChunk(in: truncated) == nil)
    }
}
