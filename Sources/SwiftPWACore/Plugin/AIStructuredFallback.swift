import Foundation

/// The shared `ai.generateJSON` fallback for backends that can't constrain
/// decoding to a schema natively. Lives in Core so every backend inherits
/// the same guarantee (see `AIBackend.generateJSON`'s default impl).
///
/// Strategy: ask the model (via plain text `generate`) to emit only JSON
/// matching the schema, parse the reply tolerantly (markdown fences and
/// surrounding prose are common), validate it shallowly, and on failure
/// make **one** repair attempt that feeds the bad output back before
/// giving up with `AIError.invalidStructuredOutput`.
///
/// Validation is intentionally shallow — it confirms the reply parses as
/// JSON and, for an object schema, that the declared `required` keys are
/// present. It is **not** a full JSON Schema validator: a backend that
/// needs strict conformance should constrain decoding natively (and
/// override `generateJSON`) rather than rely on this path.
public enum AIStructuredFallback {
    /// `generate` is injected (rather than taking the whole backend) so
    /// this is trivially unit-testable with a canned-response double.
    ///
    /// Public so an out-of-module backend (e.g. `SwiftPWALlama`) that
    /// overrides `generateJSON` can still reach this shared fallback for
    /// schemas its native constraint path can't express.
    public static func run(
        _ request: AIGenerateJSONRequest,
        generate: (AIGenerateRequest) async throws -> AIGenerateResult
    ) async throws -> JSONValue {
        let schemaJSON = (try? request.schema.encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let firstResult = try await generate(initialRequest(request, schemaJSON: schemaJSON))
        if let parsed = parseAndValidate(firstResult.text, schema: request.schema) {
            return parsed
        }

        // One repair attempt: show the model its own malformed reply.
        let repairResult = try await generate(repairRequest(request, schemaJSON: schemaJSON, bad: firstResult.text))
        if let parsed = parseAndValidate(repairResult.text, schema: request.schema) {
            return parsed
        }

        throw AIError.invalidStructuredOutput(
            "model did not return schema-valid JSON (after one repair attempt)"
        )
    }

    // MARK: - Prompt construction

    private static func initialRequest(_ request: AIGenerateJSONRequest, schemaJSON: String) -> AIGenerateRequest {
        let directive = """
        You must respond with ONLY a single JSON value that conforms to this JSON Schema. \
        Do not include any prose, explanation, or markdown code fences.

        JSON Schema:
        \(schemaJSON)
        """
        let system = request.system.map { "\($0)\n\n\(directive)" } ?? directive
        return AIGenerateRequest(
            system: system,
            prompt: request.prompt,
            images: request.images,
            audio: request.audio,
            maxTokens: request.maxTokens,
            temperature: request.temperature
        )
    }

    private static func repairRequest(
        _ request: AIGenerateJSONRequest,
        schemaJSON: String,
        bad: String
    ) -> AIGenerateRequest {
        let prompt = """
        Your previous reply was not valid JSON for the required schema. \
        Return ONLY corrected JSON conforming to the schema below — no prose, no code fences.

        JSON Schema:
        \(schemaJSON)

        Your previous (invalid) reply:
        \(bad)
        """
        return AIGenerateRequest(
            system: request.system,
            prompt: prompt,
            images: request.images,
            audio: request.audio,
            maxTokens: request.maxTokens,
            temperature: request.temperature
        )
    }

    // MARK: - Parsing / validation

    static func parseAndValidate(_ text: String, schema: JSONValue) -> JSONValue? {
        guard let value = extractJSON(text) else { return nil }
        guard validate(value, against: schema) else { return nil }
        return value
    }

    /// Pull a JSON value out of model text: try the trimmed text as-is,
    /// then strip a leading/trailing markdown code fence, then fall back to
    /// the span from the first opening bracket to the last closing bracket.
    static func extractJSON(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = decode(trimmed) { return value }

        let defenced = stripCodeFence(trimmed)
        if defenced != trimmed, let value = decode(defenced) { return value }

        if let span = bracketSpan(defenced), let value = decode(span) { return value }
        return nil
    }

    private static func decode(_ s: String) -> JSONValue? {
        guard !s.isEmpty, let data = s.data(using: .utf8) else { return nil }
        return try? JSONValue.decode(data)
    }

    /// Strip a surrounding ```` ```lang … ``` ```` markdown fence if present.
    private static func stripCodeFence(_ s: String) -> String {
        guard s.hasPrefix("```") else { return s }
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2 else { return s }
        lines.removeFirst() // ```  or ```json
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The substring from the first `{`/`[` to the matching last `}`/`]`.
    private static func bracketSpan(_ s: String) -> String? {
        let opens: Set<Character> = ["{", "["]
        let closes: Set<Character> = ["}", "]"]
        guard let start = s.firstIndex(where: { opens.contains($0) }) else { return nil }
        guard let end = s.lastIndex(where: { closes.contains($0) }), end > start else { return nil }
        return String(s[start ... end])
    }

    /// Shallow schema check: for an object schema, every name listed in
    /// `required` must be present in the result object. Anything else
    /// (non-object schemas, missing `required`) is accepted as long as it
    /// parsed as JSON.
    static func validate(_ value: JSONValue, against schema: JSONValue) -> Bool {
        guard case let .object(schemaObj) = schema else { return true }
        if case let .string(type) = schemaObj["type"], type == "object" {
            guard case let .object(valueObj) = value else { return false }
            if case let .array(required) = schemaObj["required"] {
                for entry in required {
                    if case let .string(key) = entry, valueObj[key] == nil { return false }
                }
            }
        }
        return true
    }
}
