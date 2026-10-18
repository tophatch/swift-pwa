import Foundation
@testable import SwiftPWACore
import Testing

@Suite("Sorted JSON on the wire")
struct SortedJSONTests {
    private func sorted(_ json: String) throws -> String {
        var out: [UInt8] = []
        try SortedJSON.append(Data(json.utf8), to: &out)
        return String(decoding: out, as: UTF8.self)
    }

    @Test("keys sort by code point, the order JSONEncoder's .sortedKeys uses")
    func codePointOrder() throws {
        #expect(try sorted(#"{"b":1,"a2":2,"B":3,"a10":4,"_x":5,"é":6}"#)
            == #"{"B":3,"_x":5,"a10":4,"a2":2,"b":1,"é":6}"#)
    }

    @Test("nested objects inside arrays sort too")
    func nested() throws {
        #expect(try sorted(#"{"z":[{"y":1,"x":{"d":0,"c":0}}],"a":null}"#)
            == #"{"a":null,"z":[{"x":{"c":0,"d":0},"y":1}]}"#)
    }

    @Test("whitespace between tokens is dropped, whitespace inside strings kept")
    func whitespace() throws {
        #expect(try sorted(" {\n \"b\" : [ 1 , 2 ] ,\t\"a\" : \"x y\" }\r\n") == #"{"a":"x y","b":[1,2]}"#)
    }

    @Test("strings and numbers are copied as written")
    func valuesVerbatim() throws {
        let json = #"{"k":"q\"b\\s\/é\n","n":[-0.5,1e+3,2E-2,0,-12]}"#
        #expect(try sorted(json) == json)
    }

    @Test("top-level values that aren't objects pass through")
    func fragments() throws {
        for json in ["null", "true", "false", "42", #""s""#, "[]", "{}"] {
            #expect(try sorted(json) == json)
        }
    }

    @Test("a repeated key keeps the order it was written in")
    func duplicateKeys() throws {
        #expect(try sorted(#"{"b":0,"a":1,"a":2}"#) == #"{"a":1,"a":2,"b":0}"#)
    }

    @Test("matches JSONEncoder's .sortedKeys byte for byte")
    func matchesJSONEncoder() throws {
        struct Row: Codable {
            var title: String
            var Zeta: Int
            var a10: Int
            var a2: Int
            var path: String
            var readAt: Double?
            var tags: [String]
            var nested: [String: Int]
        }
        let rows = (0 ..< 50).map {
            Row(
                title: "Chapter \($0) \"quoted\"", Zeta: $0, a10: 10, a2: 2, path: "books/\($0).xhtml",
                readAt: $0 % 2 == 0 ? nil : 1.7e9, tags: ["é", "x"], nested: ["q": 1, "B": 2, "b": 3]
            )
        }
        let sortedEncoder = JSONEncoder()
        sortedEncoder.outputFormatting = [.sortedKeys]
        let pretty = JSONEncoder()
        pretty.outputFormatting = [.prettyPrinted]
        var fromPlain: [UInt8] = []
        try SortedJSON.append(JSONEncoder().encode(rows), to: &fromPlain)
        var fromPretty: [UInt8] = []
        try SortedJSON.append(pretty.encode(rows), to: &fromPretty)
        let expected = try [UInt8](sortedEncoder.encode(rows))
        #expect(fromPlain == expected)
        #expect(fromPretty == expected)
    }

    @Test("malformed payloads are refused, not put on the wire")
    func malformed() {
        let cases = [
            "", " ", "{", #"{"a":}"#, #"{"a":1,}"#, "[1 2]", "[1,]", #"{"a" 1}"#, "{a:1}", "tru", "nul",
            "01", "-", "1.", "1e", ".5", "+1", #""\x""#, #""\u12g4""#, "\"a\u{01}b\"", #""open"#, "1 2",
            "NaN", "'s'"
        ]
        for json in cases {
            #expect(throws: SortedJSONError.self, "\(json.debugDescription)") { try sorted(json) }
        }
    }

    @Test("a string that isn't UTF-8 is refused")
    func invalidUTF8() {
        for bytes: [UInt8] in [[0x22, 0xFF, 0x22], [0x22, 0xC3, 0x22], [0x22, 0xED, 0xA0, 0x80, 0x22]] {
            var out: [UInt8] = []
            #expect(throws: SortedJSONError.malformed(offset: 0)) {
                try SortedJSON.append(Data(bytes), to: &out)
            }
        }
    }

    @Test("nesting past the limit is refused")
    func depth() throws {
        let limit = SortedJSON.maxDepth
        let atLimit = String(repeating: "[", count: limit) + String(repeating: "]", count: limit)
        #expect(try sorted(atLimit) == atLimit)
        let past = "[" + atLimit + "]"
        #expect(throws: SortedJSONError.tooDeep) { try sorted(past) }
    }

    @Test("appending keeps what was already in the buffer")
    func appends() throws {
        var out = Array("prefix:".utf8)
        try SortedJSON.append(Data(#"{"b":1,"a":2}"#.utf8), to: &out)
        #expect(String(decoding: out, as: UTF8.self) == #"prefix:{"a":2,"b":1}"#)
    }
}
