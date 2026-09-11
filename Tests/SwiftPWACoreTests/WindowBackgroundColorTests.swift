@testable import SwiftPWACore
import Testing

@Suite("WindowBackgroundColor")
struct WindowBackgroundColorTests {
    @Test("a string literal is still one colour for both appearances")
    func stringLiteral() {
        let background: WindowBackgroundColor = "#F4F7F5"
        #expect(background == .single("#F4F7F5"))
        #expect(background.light == "#F4F7F5")
        #expect(background.dark == "#F4F7F5")
        #expect(background.isPair == false)
    }

    @Test("a pair keeps both halves apart")
    func pair() {
        let background = WindowBackgroundColor.dayNight(light: "#F4F4F2", dark: "#0C0D0E")
        #expect(background.hex(dark: false) == "#F4F4F2")
        #expect(background.hex(dark: true) == "#0C0D0E")
        #expect(background.isPair)
    }

    @Test("resolves each half to a parsed colour")
    func resolves() throws {
        let background = WindowBackgroundColor(light: "#FFFFFF", dark: "#000")
        #expect(try #require(background.rgb(dark: false)).bytes == (0xFF, 0xFF, 0xFF))
        #expect(try #require(background.rgb(dark: true)).bytes == (0x00, 0x00, 0x00))
    }

    /// A backend treats `nil` as "no background configured" rather than
    /// substituting one the app never asked for, so bad hex has to stay nil
    /// per half — a pair with one good half still can't be painted.
    @Test("unparseable hex resolves to nil for that appearance only")
    func badHex() {
        let background = WindowBackgroundColor.dayNight(light: "#F4F4F2", dark: "not-a-colour")
        #expect(background.rgb(dark: false) != nil)
        #expect(background.rgb(dark: true) == nil)
    }
}
