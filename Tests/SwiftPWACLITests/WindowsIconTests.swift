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
}
