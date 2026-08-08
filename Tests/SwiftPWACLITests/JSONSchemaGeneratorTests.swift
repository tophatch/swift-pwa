import Foundation
@testable import SwiftPWACLISupport
import SwiftPWACore
import Testing

/// `BridgeSchema` → JSON Schema, the lowering an MCP tool's `inputSchema` needs.
@Suite("JSON Schema generation")
struct JSONSchemaGeneratorTests {
    @Test("primitives map onto JSON Schema's type names")
    func primitives() {
        #expect(JSONSchemaGenerator.schema(for: .bool) == .object(["type": .string("boolean")]))
        #expect(JSONSchemaGenerator.schema(for: .string) == .object(["type": .string("string")]))
        // JSON has one number type; JSON Schema distinguishes them, and an agent
        // that sends 1.5 for an Int would otherwise fail at the decoder.
        #expect(JSONSchemaGenerator.schema(for: .int) == .object(["type": .string("integer")]))
        #expect(JSONSchemaGenerator.schema(for: .double) == .object(["type": .string("number")]))
    }

    @Test("a type with no BridgeType conformance becomes the empty schema")
    func unknownIsAnySchema() {
        #expect(JSONSchemaGenerator.schema(for: .unknown) == .object([:]))
    }

    @Test("arrays and dictionaries describe their element type")
    func containers() {
        #expect(JSONSchemaGenerator.schema(for: .array(.string)) == .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")])
        ]))
        #expect(JSONSchemaGenerator.schema(for: .dictionary(.int)) == .object([
            "type": .string("object"),
            "additionalProperties": .object(["type": .string("integer")])
        ]))
    }

    @Test("a string enum becomes an enum constraint, so the agent sees the options")
    func stringEnum() {
        let schema = JSONSchemaGenerator.schema(for: .stringEnum(name: "Sort", cases: ["title", "recent"]))
        #expect(schema["type"] == .string("string"))
        #expect(schema["title"] == .string("Sort"))
        #expect(schema["enum"] == .array([.string("title"), .string("recent")]))
    }

    @Test("optional fields are described but left out of `required`")
    func optionalityIsExpressedByRequired() {
        let schema = JSONSchemaGenerator.schema(for: .object(name: "Args", fields: [
            BridgeField(name: "id", schema: .string),
            BridgeField(name: "limit", schema: .optional(.int))
        ]))
        #expect(schema["properties"]?["limit"] == .object(["type": .string("integer")]))
        #expect(schema["required"] == .array([.string("id")]))
    }

    @Test("an all-optional object declares no required fields at all")
    func noRequiredKeyWhenEverythingIsOptional() {
        let schema = JSONSchemaGenerator.schema(for: .object(name: "Args", fields: [
            BridgeField(name: "limit", schema: .optional(.int))
        ]))
        #expect(schema["required"] == nil)
    }

    @Test("objects are strict, so an invented field is reported rather than dropped")
    func objectsRejectExtraProperties() {
        let schema = JSONSchemaGenerator.schema(for: .object(name: "Args", fields: []))
        #expect(schema["additionalProperties"] == .bool(false))
        #expect(schema["title"] == .string("Args"))
    }

    @Test("nested objects lower recursively")
    func nesting() {
        let schema = JSONSchemaGenerator.schema(for: .object(name: "Outer", fields: [
            BridgeField(name: "inner", schema: .array(.object(name: "Inner", fields: [
                BridgeField(name: "flag", schema: .bool)
            ])))
        ]))
        #expect(schema["properties"]?["inner"]?["items"]?["properties"]?["flag"]
            == .object(["type": .string("boolean")]))
    }

    // MARK: - Tool input schemas

    @Test("a no-argument command gets an empty object schema")
    func voidToolInput() {
        let schema = JSONSchemaGenerator.toolInputSchema(for: .void)
        #expect(schema?["type"] == .string("object"))
        #expect(schema?["properties"] == .object([:]))
    }

    @Test("only objects and no-argument commands can be tool inputs", arguments: [
        BridgeSchema.string, .int, .array(.string), .dictionary(.string), .unknown,
        .stringEnum(name: "E", cases: ["a"])
    ])
    func nonObjectToolInputsAreRefused(schema: BridgeSchema) {
        // MCP requires inputSchema to be an object; a bare value has no field
        // name to hand the agent, and inventing one would be a guess.
        #expect(JSONSchemaGenerator.toolInputSchema(for: schema) == nil)
    }
}
