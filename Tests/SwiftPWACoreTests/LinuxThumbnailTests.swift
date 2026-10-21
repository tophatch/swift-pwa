#if os(Linux)
    import Foundation
    @testable import SwiftPWACore
    import Testing

    @Suite("Linux thumbnails")
    struct LinuxThumbnailTests {
        @Test("tEXt chunks added to a PNG read back, with the CRC PNG specifies")
        func pngText() throws {
            #expect(PNGChunks.crc32(Array("IEND".utf8)) == 0xAE42_6082)
            // 1×1 RGB, as a thumbnailer writes one.
            let ihdr: [UInt8] = Array("IHDR".utf8) + [0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0]
            func chunk(_ body: [UInt8]) -> [UInt8] {
                let length = body.count - 4
                let crc = PNGChunks.crc32(body)
                return [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) } + body
                    + [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: crc >> UInt32($0)) }
            }
            let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk(ihdr) + chunk(Array("IEND".utf8)))
            let tagged = PNGChunks.addingText(["Thumb::URI": "file:///a%20b.pdf", "Thumb::MTime": "12"], to: png)
            #expect(PNGChunks.text(tagged) == ["Thumb::URI": "file:///a%20b.pdf", "Thumb::MTime": "12"])
            let dimensions = try #require(PNGChunks.dimensions(tagged))
            #expect(dimensions.width == 1 && dimensions.height == 1)
        }

        @Test("an Exec line splits as the desktop-entry spec quotes it")
        func execTokens() {
            #expect(ThumbnailerEntry.tokenize("papers-thumbnailer -s %s %u %o")
                == ["papers-thumbnailer", "-s", "%s", "%u", "%o"])
            #expect(ThumbnailerEntry.tokenize(#"sh -c "thumb \"%i\" > %o""#) == ["sh", "-c", #"thumb "%i" > %o"#])
        }
    }
#endif
