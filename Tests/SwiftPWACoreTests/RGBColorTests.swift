@testable import SwiftPWACore
import Testing

@Suite("RGBColor")
struct RGBColorTests {
    @Test("parses #RRGGBB")
    func sixDigit() throws {
        let c = try #require(RGBColor(hex: "#F4F7F5"))
        #expect(c.bytes == (0xF4, 0xF7, 0xF5))
    }

    @Test("parses without a leading #")
    func noHash() throws {
        let c = try #require(RGBColor(hex: "FF8000"))
        #expect(c.bytes == (0xFF, 0x80, 0x00))
    }

    @Test("expands #RGB shorthand")
    func shorthand() throws {
        let c = try #require(RGBColor(hex: "#0AF"))
        #expect(c.bytes == (0x00, 0xAA, 0xFF))
    }

    @Test("black and white map to 0 and 1")
    func extremes() throws {
        #expect(try #require(RGBColor(hex: "#000000")).red == 0.0)
        let white = try #require(RGBColor(hex: "#ffffff"))
        #expect(white.red == 1.0 && white.green == 1.0 && white.blue == 1.0)
    }

    @Test(
        "rejects malformed input",
        arguments: ["", "#", "#12", "#12345", "#1234567", "ZZZZZZ", "#GGG", "rebeccapurple"]
    )
    func rejects(_ bad: String) {
        #expect(RGBColor(hex: bad) == nil)
    }
}
