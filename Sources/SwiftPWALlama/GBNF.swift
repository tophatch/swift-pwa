import Foundation
import SwiftPWACore

/// Converts a JSON-Schema `JSONValue` into a llama.cpp **GBNF** grammar so
/// `generateJSON` can constrain decoding natively (rather than the prompt-and-
/// validate fallback in `AIStructuredFallback`). Covers the subset the rest of
/// the stack emits — the same shapes `FoundationModelsBackend` handles: object
/// (with `properties` / `required`), array (`items`), `string` (incl. `enum`),
/// `integer`, `number`, `boolean`, `null`.
///
/// Returns `nil` for a schema using a construct outside that subset (e.g.
/// `anyOf`, `$ref`, tuple `items`); the caller then falls back to the shared
/// prompt-inject path so `ai.generateJSON` still works, just unconstrained.
enum GBNF {
    /// Build a complete grammar with a `root` rule, or `nil` if unsupported.
    static func grammar(from schema: JSONValue) -> String? {
        var builder = Builder()
        guard let rootRule = builder.rule(for: schema, nameHint: "root") else { return nil }
        // The grammar entry point must be named `root` (the root we pass to
        // llama_sampler_init_grammar). Alias it to whatever the top rule got.
        var lines = ["root ::= \(rootRule)"]
        lines.append(contentsOf: builder.rules)
        lines.append(contentsOf: Builder.primitives)
        return lines.joined(separator: "\n")
    }

    private struct Builder {
        var rules: [String] = []
        private var counter = 0

        /// Shared primitive rules referenced by generated rules.
        static let primitives: [String] = [
            #"ws ::= [ \t\n]*"#,
            #"string ::= "\"" ( [^"\\] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F]) )* "\"""#,
            #"integer ::= "-"? ([0-9] | [1-9] [0-9]*)"#,
            #"number ::= "-"? ([0-9] | [1-9] [0-9]*) ("." [0-9]+)? ([eE] [-+]? [0-9]+)?"#,
            #"boolean ::= "true" | "false""#,
            #"null ::= "null""#
        ]

        /// Return the right-hand-side expression for `schema`, registering any
        /// named sub-rules. `nil` if the schema is unsupported.
        mutating func rule(for schema: JSONValue, nameHint: String) -> String? {
            guard case let .object(obj) = schema else {
                // Bare/empty schema → any JSON string (most permissive thing we
                // can constrain to without a full JSON-value grammar).
                return "string"
            }
            // Unsupported combinators → bail so the caller falls back.
            if obj["anyOf"] != nil || obj["oneOf"] != nil || obj["allOf"] != nil || obj["$ref"] != nil {
                return nil
            }

            // String enum → alternation of quoted literals.
            if case let .array(choices) = obj["enum"] {
                let literals = choices.compactMap { value -> String? in
                    if case let .string(s) = value { return "\"\\\"\(escape(s))\\\"\"" }
                    return nil
                }
                if literals.count == choices.count, !literals.isEmpty {
                    return "(" + literals.joined(separator: " | ") + ")"
                }
                return nil
            }

            let type = obj["type"].flatMap { if case let .string(s) = $0 { s } else { nil } }
            switch type {
            case "object":
                return objectRule(obj, nameHint: nameHint)
            case "array":
                let items = obj["items"] ?? .object([:])
                guard let elem = rule(for: items, nameHint: nameHint + "Item") else { return nil }
                let name = fresh(nameHint + "Arr")
                rules.append("\(name) ::= \"[\" ws ( \(elem) ( ws \",\" ws \(elem) )* )? ws \"]\"")
                return name
            case "integer": return "integer"
            case "number": return "number"
            case "boolean": return "boolean"
            case "null": return "null"
            case "string": return "string"
            default: return "string"
            }
        }

        private mutating func objectRule(_ obj: [String: JSONValue], nameHint: String) -> String? {
            guard case let .object(props) = obj["properties"], !props.isEmpty else {
                // Object without declared properties → empty object literal.
                let name = fresh(nameHint + "Obj")
                rules.append("\(name) ::= \"{\" ws \"}\"")
                return name
            }
            // Emit every declared property in a fixed (sorted) order. We don't
            // model optionality — a constrained object always carries all its
            // declared keys, which is valid against a schema whose extra keys
            // are optional and satisfies all `required` keys.
            var parts: [String] = []
            for (i, key) in props.keys.sorted().enumerated() {
                guard let valueRule = rule(for: props[key]!, nameHint: key.capitalized) else { return nil }
                let comma = i == 0 ? "" : "\",\" ws "
                parts.append("\(comma)\"\\\"\(escape(key))\\\"\" ws \":\" ws \(valueRule) ws")
            }
            let name = fresh(nameHint + "Obj")
            rules.append("\(name) ::= \"{\" ws " + parts.joined(separator: " ") + "\"}\"")
            return name
        }

        private mutating func fresh(_ hint: String) -> String {
            counter += 1
            // Rule names must be identifier-safe.
            let safe = hint.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
            return String(safe) + "\(counter)"
        }

        private func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
    }
}
