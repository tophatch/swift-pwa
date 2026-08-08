import Foundation
import SwiftPWACore

/// Lowers a ``BridgeSchema`` to a JSON Schema document — the shape an MCP tool
/// definition's `inputSchema` needs, and the same structural information the
/// TypeScript generator emits as an interface.
///
/// Pure: schema in, `BridgeJSON` out. The two generators are deliberately
/// separate rather than one parameterised emitter — they answer to different
/// specs (TypeScript's type grammar vs JSON Schema 2020-12) and the places they
/// diverge (optionality, `additionalProperties`, enum representation) are
/// exactly the interesting parts.
enum JSONSchemaGenerator {
    /// The `inputSchema` for a tool whose arguments are `schema`, or `nil` when
    /// the schema can't be an MCP tool input at all.
    ///
    /// MCP requires `inputSchema` to be an object schema, so only `.void` (no
    /// arguments) and `.object` qualify. A command taking a bare `String` has
    /// no field name to give the agent, so it's rejected rather than invented.
    static func toolInputSchema(for schema: BridgeSchema) -> BridgeJSON? {
        switch schema {
        case .void:
            .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])
        case .object:
            self.schema(for: schema)
        default:
            nil
        }
    }

    /// The JSON Schema for any bridge schema, as a `BridgeJSON` tree.
    static func schema(for schema: BridgeSchema) -> BridgeJSON {
        switch schema {
        // No `BridgeType` conformance — nothing is known about the shape, and
        // JSON Schema spells "any value" as the empty schema.
        case .unknown:
            .object([:])
        case .void:
            .object(["type": .string("null")])
        case .bool:
            .object(["type": .string("boolean")])
        case .int:
            .object(["type": .string("integer")])
        case .double:
            .object(["type": .string("number")])
        case .string:
            .object(["type": .string("string")])
        // Optionality is carried by omission from `required` (see `object`), so
        // an optional lowers to its wrapped schema. A caller sending an explicit
        // `null` instead of omitting the key is the rarer shape and isn't worth
        // an `anyOf` wrapper around every optional field.
        case let .optional(inner):
            self.schema(for: inner)
        case let .array(element):
            .object(["type": .string("array"), "items": self.schema(for: element)])
        case let .dictionary(value):
            .object(["type": .string("object"), "additionalProperties": self.schema(for: value)])
        case let .object(name, fields):
            objectSchema(name: name, fields: fields)
        case let .stringEnum(name, cases):
            .object([
                "type": .string("string"),
                "title": .string(name),
                "enum": .array(cases.map { .string($0) })
            ])
        }
    }

    private static func objectSchema(name: String, fields: [BridgeField]) -> BridgeJSON {
        var properties: [String: BridgeJSON] = [:]
        var required: [String] = []
        for field in fields {
            properties[field.name] = schema(for: field.schema)
            if case .optional = field.schema { continue }
            required.append(field.name)
        }
        var out: [String: BridgeJSON] = [
            "type": .string("object"),
            "title": .string(name),
            "properties": .object(properties),
            // Strict by default: an agent that invents a field should be told,
            // not silently ignored by the decoder on the other side.
            "additionalProperties": .bool(false)
        ]
        if !required.isEmpty {
            out["required"] = .array(required.sorted().map { .string($0) })
        }
        return .object(out)
    }
}
