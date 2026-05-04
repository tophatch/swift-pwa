import Foundation
@testable import SwiftPWACore
import Testing

@Suite("JSONValue")
struct JSONValueTests {
    @Test("round-trips primitives, arrays, objects")
    func roundTrip() throws {
        let value: JSONValue = .object([
            "n": .number(1.5),
            "s": .string("hi"),
            "b": .bool(true),
            "x": .null,
            "a": .array([.number(1), .number(2)]),
            "nested": .object(["k": .string("v")])
        ])
        let data = try value.encoded()
        let decoded = try JSONValue.decode(data)
        #expect(decoded == value)
    }

    @Test("decodes JSON fragments")
    func fragments() throws {
        #expect(try JSONValue.decode(Data("null".utf8)) == .null)
        #expect(try JSONValue.decode(Data("true".utf8)) == .bool(true))
        #expect(try JSONValue.decode(Data("42".utf8)) == .number(42))
        #expect(try JSONValue.decode(Data(#""hi""#.utf8)) == .string("hi"))
    }
}
