import Foundation
@testable import SwiftPWACore
import Testing

/// The reflecting `Decodable` probe that derives a `BridgeSchema` from a plain
/// `Codable` type with no annotation (the macro-free schema source for codegen).
@Suite("Schema reflection (probe)")
struct SchemaReflectionTests {
    private func schema(_ type: Any.Type) -> BridgeSchema { SchemaReflection.schema(for: type) }

    @Test("scalars map to their schema")
    func scalars() {
        #expect(schema(Bool.self) == .bool)
        #expect(schema(String.self) == .string)
        #expect(schema(Int.self) == .int)
        #expect(schema(Int64.self) == .int)
        #expect(schema(UInt8.self) == .int)
        #expect(schema(Double.self) == .double)
        #expect(schema(Float.self) == .double)
    }

    @Test("a flat struct probes to an ordered object schema")
    func flatStruct() {
        struct S: Codable { let a: Int; let b: String; let c: Bool }
        #expect(schema(S.self) == .object(name: "S", fields: [
            .init(name: "a", schema: .int),
            .init(name: "b", schema: .string),
            .init(name: "c", schema: .bool)
        ]))
    }

    @Test("optionals, arrays, and string-keyed dictionaries")
    func containers() {
        struct S: Codable {
            let opt: String?
            let list: [Int]
            let map: [String: Bool]
            let matrix: [[Double]]
        }
        #expect(schema(S.self) == .object(name: "S", fields: [
            .init(name: "opt", schema: .optional(.string)),
            .init(name: "list", schema: .array(.int)),
            .init(name: "map", schema: .dictionary(.bool)),
            .init(name: "matrix", schema: .array(.array(.double)))
        ]))
    }

    @Test("nested structs recurse")
    func nested() {
        struct Inner: Codable { let x: Int }
        struct Outer: Codable { let inner: Inner; let inners: [Inner] }
        #expect(schema(Outer.self) == .object(name: "Outer", fields: [
            .init(name: "inner", schema: .object(name: "Inner", fields: [.init(name: "x", schema: .int)])),
            .init(name: "inners", schema: .array(.object(name: "Inner", fields: [.init(name: "x", schema: .int)])))
        ]))
    }

    @Test("an explicit BridgeType conformance short-circuits the probe")
    func bridgeTypeWins() {
        struct Custom: BridgeType {
            let ignored: Int
            static var bridgeSchema: BridgeSchema {
                .stringEnum(name: "Custom", cases: ["x"])
            }
        }
        #expect(schema(Custom.self) == .stringEnum(name: "Custom", cases: ["x"]))
    }

    @Test("EmptyArgs / EmptyResult are void")
    func empties() {
        #expect(schema(EmptyArgs.self) == .void)
        #expect(schema(EmptyResult.self) == .void)
    }

    @Test("a bare enum field can't be probed → the struct degrades to .unknown")
    func bareEnumDegrades() {
        enum E: String, Codable { case a, b }
        struct S: Codable { let e: E }
        #expect(schema(S.self) == .unknown)
    }
}
