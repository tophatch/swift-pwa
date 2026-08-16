import Foundation
@testable import SwiftPWACLISupport
import Testing

/// The JS-literal escaping behind `drive eval`'s promise awaiting.
///
/// Two things get interpolated into the wrapper script: the `window` key the
/// CLI mints, and **the caller's own script**, which is embedded as a string
/// literal so indirect `eval` can run it as a program. Both have to survive
/// being embedded rather than end the literal early — the caller's script
/// especially, since it routinely contains quotes. The rest of the path needs a
/// live page and is covered by driving one.
@Suite("drive eval promise awaiting")
struct DriveEvalAwaitTests {
    @Test("quotes and backslashes can't end the literal early")
    func escapesQuotesAndBackslashes() {
        #expect(DriverClient.jsStringLiteral("plain") == "\"plain\"")
        #expect(DriverClient.jsStringLiteral("a\"b") == "\"a\\\"b\"")
        #expect(DriverClient.jsStringLiteral("a\\b") == "\"a\\\\b\"")
        // The pair that would otherwise close the string and start a statement.
        #expect(DriverClient.jsStringLiteral("\";alert(1);\"") == "\"\\\";alert(1);\\\"\"")
    }

    @Test("newlines and control characters are escaped, not embedded raw")
    func escapesControlCharacters() {
        #expect(DriverClient.jsStringLiteral("a\nb") == "\"a\\nb\"")
        #expect(DriverClient.jsStringLiteral("a\rb") == "\"a\\rb\"")
        #expect(DriverClient.jsStringLiteral("a\u{0}b") == "\"a\\u0000b\"")
    }

    /// U+2028 / U+2029 are line terminators to a JS parser but not to JSON, so
    /// a literal carrying them raw is a syntax error inside a script even
    /// though the string itself looks fine.
    @Test("JS-only line terminators are escaped")
    func escapesUnicodeLineTerminators() {
        #expect(DriverClient.jsStringLiteral("a\u{2028}b") == "\"a\\u2028b\"")
        #expect(DriverClient.jsStringLiteral("a\u{2029}b") == "\"a\\u2029b\"")
    }
}
