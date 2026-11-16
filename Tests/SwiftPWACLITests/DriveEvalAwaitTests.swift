import Foundation
#if canImport(JavaScriptCore)
    import JavaScriptCore
#endif
@testable import SwiftPWACLISupport
@testable import SwiftPWACore
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

    // MARK: - What the wrapper's first answer means (#351)

    @Test("the wrapper's own answers are read as what they say")
    func readsWrapperAnswers() throws {
        #expect(try DriverClient.startOutcome(of: .object(["cspBlocked": .bool(true)])) == .cspBlocked)
        #expect(try DriverClient.startOutcome(of: .object(["settled": .bool(true), "value": .number(2)]))
            == .settled(.number(2)))
        #expect(try DriverClient.startOutcome(of: .object(["settled": .bool(true)])) == .settled(.null))
        #expect(try DriverClient.startOutcome(of: .object(["settled": .bool(false)])) == .pending)
    }

    @Test("a caught throw is an error carrying the exception, not a pending promise")
    func throwIsAnError() {
        do {
            _ = try DriverClient.startOutcome(of: .object(["threw": .string("ReferenceError: x is not defined")]))
            Issue.record("a throw was read as a value")
        } catch let DriveError.remote(code, message) {
            #expect(code == "E_EVAL_THREW")
            #expect(message == "ReferenceError: x is not defined")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    /// WebView2 completes a failed evaluation with `null`. Before #351 that
    /// read as a pending promise, and the poll that followed blamed a
    /// navigation that never happened.
    @Test("an answer that isn't the wrapper's is an error, not a pending promise")
    func foreignAnswerIsAnError() {
        for reply: BridgeJSON in [.null, .object([:]), .string("x")] {
            #expect(throws: DriveError.self, "accepted \(reply)") {
                _ = try DriverClient.startOutcome(of: reply)
            }
        }
    }

    #if canImport(JavaScriptCore)
        /// The wrapper itself, run in a real JS engine: the outcome a page
        /// would give it, with no webview in the way.
        private func run(_ script: String) throws -> BridgeJSON {
            let context = try #require(JSContext())
            context.evaluateScript("var window = this;")
            let wrapper = DriverClient.awaitingScript(script, key: "__k")
            let json = try #require(context.evaluateScript("JSON.stringify(\(wrapper))")?.toString())
            return try JSONDecoder().decode(BridgeJSON.self, from: Data(json.utf8))
        }

        @Test("in a JS engine: a throw is caught with its name and message")
        func wrapperCatchesThrow() throws {
            let reply = try run("JSON.stringify({x: notDefinedAnywhere})")
            let message = try #require(reply["threw"]?.stringValue)
            #expect(message.hasPrefix("ReferenceError: "))
            #expect(message.contains("notDefinedAnywhere"))
        }

        @Test("in a JS engine: a thrown non-Error and a syntax error are caught too")
        func wrapperCatchesOddThrows() throws {
            #expect(try run("throw 'plain'")["threw"]?.stringValue == "plain")
            #expect(try run("1 +")["threw"]?.stringValue?.hasPrefix("SyntaxError: ") == true)
        }

        @Test("in a JS engine: values, statements and promises keep their old answers")
        func wrapperKeepsValues() throws {
            #expect(try run("window.a = 1; window.b = 2") == .object(["settled": .bool(true), "value": .number(2)]))
            #expect(try run("undefined") == .object(["settled": .bool(true), "value": .null]))
            #expect(try run("Promise.resolve(1)") == .object(["settled": .bool(false)]))
        }
    #endif
}
