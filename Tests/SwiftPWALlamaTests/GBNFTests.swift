import SwiftPWACore
@testable import SwiftPWALlama
import Testing

/// Unit tests for the JSON-Schema → GBNF translation. No model required, so
/// these run everywhere (the e2e generation tests in `LlamaBackendTests` skip
/// without a GGUF on disk).
@Suite("GBNF grammar generation")
struct GBNFTests {
    @Test("object schema produces a root rule with its keys")
    func objectSchema() throws {
        let schema = JSONValue.object([
            "type": .string("object"),
            "required": .array([.string("name"), .string("age")]),
            "properties": .object([
                "name": .object(["type": .string("string")]),
                "age": .object(["type": .string("integer")])
            ])
        ])
        let grammar = try #require(GBNF.grammar(from: schema))
        #expect(grammar.contains("root ::="))
        #expect(grammar.contains("\\\"name\\\"")) // a quoted "name" key literal
        #expect(grammar.contains("\\\"age\\\""))
        #expect(grammar.contains("integer ::=")) // primitive pulled in
        #expect(grammar.contains("string ::="))
    }

    @Test("string enum becomes an alternation of literals")
    func enumSchema() throws {
        let schema = JSONValue.object([
            "type": .string("string"),
            "enum": .array([.string("red"), .string("green"), .string("blue")])
        ])
        let grammar = try #require(GBNF.grammar(from: schema))
        #expect(grammar.contains("\\\"red\\\""))
        #expect(grammar.contains("\\\"green\\\""))
        #expect(grammar.contains(" | ")) // alternation
    }

    @Test("array schema wraps its element rule")
    func arraySchema() throws {
        let schema = JSONValue.object([
            "type": .string("array"),
            "items": .object(["type": .string("number")])
        ])
        let grammar = try #require(GBNF.grammar(from: schema))
        #expect(grammar.contains("\"[\"")) // opening bracket literal
        #expect(grammar.contains("number ::="))
    }

    @Test("unsupported combinators fall back (nil)")
    func unsupportedFallsBack() {
        // `anyOf` is outside our subset — the backend should fall back to the
        // shared prompt-and-validate path rather than emit a broken grammar.
        let schema = JSONValue.object([
            "anyOf": .array([
                .object(["type": .string("string")]),
                .object(["type": .string("integer")])
            ])
        ])
        #expect(GBNF.grammar(from: schema) == nil)
    }

    @Test("scalar types map to primitives")
    func scalars() throws {
        for (type, rule) in [("integer", "integer"), ("number", "number"), ("boolean", "boolean")] {
            let schema = JSONValue.object(["type": .string(type)])
            let grammar = try #require(GBNF.grammar(from: schema))
            #expect(grammar.contains("\(rule) ::="))
        }
    }
}
