import Foundation
import SwiftPWACore

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// An `AIBackend` backed by Apple's on-device **Foundation Models** — the
/// system language model (Apple Intelligence), no download, free, private.
///
/// Opt in like any backend:
/// ```swift
/// import SwiftPWAFoundationModels
/// ctx.use(AIPlugin(FoundationModelsBackend()))
/// ```
///
/// Reports `available: false` (so the app falls back to its own tier) when
/// the framework is absent (built against an older SDK), the OS is below
/// macOS 26 / iOS 26, or the system model isn't ready (device unsupported,
/// Apple Intelligence off, model still downloading).
///
/// Provides text (`generate`), token streaming (`generateStream`), and
/// **native schema-constrained** structured output (`generateJSON`, via
/// Foundation Models' guided generation — so `structuredOutput: true`). The
/// base system model is text-only, so vision / image / audio stay
/// unsupported and the app sees those capability flags as `false`.
///
/// Stateless: a fresh `LanguageModelSession` per call, so concurrent calls
/// don't share a session. Foundation Models arbitrates device compute
/// itself, so no app-level serialization is needed here (unlike a
/// single-context backend such as llama.cpp).
public struct FoundationModelsBackend: AIBackend {
    public init() {}

    public func info() async -> AICapabilities {
        #if canImport(FoundationModels)
            if #available(macOS 26, iOS 26, *), case .available = SystemLanguageModel.default.availability {
                return AICapabilities(
                    available: true,
                    backend: AIBackendID.appleFoundationModels,
                    model: "system",
                    streaming: true,
                    structuredOutput: true
                )
            }
        #endif
        return AICapabilities(available: false, backend: AIBackendID.appleFoundationModels)
    }

    public func generate(_ request: AIGenerateRequest) async throws -> AIGenerateResult {
        #if canImport(FoundationModels)
            if #available(macOS 26, iOS 26, *) {
                try Self.ensureAvailable()
                let session = LanguageModelSession(instructions: request.system)
                do {
                    let response = try await session.respond(to: request.prompt, options: Self.options(request))
                    return AIGenerateResult(text: response.content, backend: AIBackendID.appleFoundationModels)
                } catch {
                    throw AIError.generationFailed("\(error)")
                }
            }
        #endif
        throw Self.unavailable
    }

    public func generateStream(_ request: AIGenerateRequest) -> AsyncThrowingStream<AIChunk, any Error> {
        #if canImport(FoundationModels)
            if #available(macOS 26, iOS 26, *) {
                return AsyncThrowingStream { continuation in
                    let task = Task {
                        do {
                            try Self.ensureAvailable()
                            let session = LanguageModelSession(instructions: request.system)
                            // Foundation Models streams *cumulative* snapshots;
                            // emit the newly-appended suffix as each delta.
                            var emitted = ""
                            for try await snapshot in session.streamResponse(
                                to: request.prompt, options: Self.options(request)
                            ) {
                                let full = snapshot.content
                                if full.hasPrefix(emitted), full.count > emitted.count {
                                    continuation.yield(.delta(String(full.dropFirst(emitted.count))))
                                } else if full != emitted {
                                    // Non-monotonic update (rare) — resend whole.
                                    continuation.yield(.delta(full))
                                }
                                emitted = full
                            }
                            continuation.yield(.done)
                            continuation.finish()
                        } catch let error as AIError {
                            continuation.finish(throwing: error)
                        } catch {
                            continuation.finish(throwing: AIError.generationFailed("\(error)"))
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        #endif
        return AsyncThrowingStream { $0.finish(throwing: Self.unavailable) }
    }

    public func generateJSON(_ request: AIGenerateJSONRequest) async throws -> JSONValue {
        #if canImport(FoundationModels)
            if #available(macOS 26, iOS 26, *) {
                try Self.ensureAvailable()
                let session = LanguageModelSession(instructions: request.system)
                do {
                    let schema = try Self.generationSchema(from: request.schema)
                    let response = try await session.respond(
                        to: request.prompt, schema: schema, options: Self.options(request)
                    )
                    return Self.jsonValue(from: response.content)
                } catch let error as AIError {
                    throw error
                } catch {
                    throw AIError.invalidStructuredOutput("\(error)")
                }
            }
        #endif
        throw Self.unavailable
    }

    // MARK: - Helpers

    private static var unavailable: AIError {
        .unavailable("Foundation Models is unavailable (needs macOS 26 / iOS 26 and Apple Intelligence enabled)")
    }

    #if canImport(FoundationModels)
        @available(macOS 26, iOS 26, *)
        private static func ensureAvailable() throws {
            guard case .available = SystemLanguageModel.default.availability else { throw unavailable }
        }

        @available(macOS 26, iOS 26, *)
        private static func options(_ request: AIGenerateRequest) -> GenerationOptions {
            GenerationOptions(temperature: request.temperature, maximumResponseTokens: request.maxTokens)
        }

        @available(macOS 26, iOS 26, *)
        private static func options(_ request: AIGenerateJSONRequest) -> GenerationOptions {
            GenerationOptions(temperature: request.temperature, maximumResponseTokens: request.maxTokens)
        }

        /// Build a Foundation Models `GenerationSchema` from a JSON-Schema
        /// `JSONValue` so decoding is constrained to it. Supports object /
        /// array / string (incl. `enum`) / integer / number / boolean.
        @available(macOS 26, iOS 26, *)
        static func generationSchema(from schema: JSONValue) throws -> GenerationSchema {
            var counter = 0
            let root = try dynamicSchema(from: schema, nameHint: "Root", counter: &counter)
            return try GenerationSchema(root: root, dependencies: [])
        }

        @available(macOS 26, iOS 26, *)
        private static func dynamicSchema(
            from schema: JSONValue, nameHint: String, counter: inout Int
        ) throws -> DynamicGenerationSchema {
            guard case let .object(obj) = schema else {
                // A bare/unconstrained schema → free-form string.
                return DynamicGenerationSchema(type: String.self)
            }
            let type = obj["type"].flatMap { if case let .string(s) = $0 { s } else { nil } }

            // String enum → a choice schema.
            if case let .array(choices) = obj["enum"] {
                let names = choices.compactMap { if case let .string(s) = $0 { s } else { nil } }
                if !names.isEmpty {
                    counter += 1
                    return DynamicGenerationSchema(name: "\(nameHint)\(counter)", anyOf: names)
                }
            }

            switch type {
            case "object":
                counter += 1
                let required: Set<String> = {
                    if case let .array(items) = obj["required"] {
                        return Set(items.compactMap { if case let .string(s) = $0 { s } else { nil } })
                    }
                    return []
                }()
                var properties: [DynamicGenerationSchema.Property] = []
                if case let .object(props) = obj["properties"] {
                    // Sorted for a stable, deterministic schema.
                    for key in props.keys.sorted() {
                        let sub = try dynamicSchema(from: props[key]!, nameHint: key.capitalized, counter: &counter)
                        properties.append(.init(name: key, schema: sub, isOptional: !required.contains(key)))
                    }
                }
                return DynamicGenerationSchema(name: "\(nameHint)\(counter)", properties: properties)
            case "array":
                let items = obj["items"] ?? .object([:])
                let element = try dynamicSchema(from: items, nameHint: "\(nameHint)Item", counter: &counter)
                return DynamicGenerationSchema(arrayOf: element)
            case "integer":
                return DynamicGenerationSchema(type: Int.self)
            case "number":
                return DynamicGenerationSchema(type: Double.self)
            case "boolean":
                return DynamicGenerationSchema(type: Bool.self)
            default: // "string" and anything unspecified
                return DynamicGenerationSchema(type: String.self)
            }
        }

        /// Convert Foundation Models' `GeneratedContent` to a `JSONValue`. The
        /// `Kind` cases map one-to-one.
        @available(macOS 26, iOS 26, *)
        static func jsonValue(from content: GeneratedContent) -> JSONValue {
            switch content.kind {
            case .null:
                return .null
            case let .bool(b):
                return .bool(b)
            case let .number(n):
                return .number(n)
            case let .string(s):
                return .string(s)
            case let .array(items):
                return .array(items.map(jsonValue(from:)))
            case let .structure(properties, orderedKeys):
                var object: [String: JSONValue] = [:]
                for key in orderedKeys {
                    if let value = properties[key] { object[key] = jsonValue(from: value) }
                }
                return .object(object)
            @unknown default:
                return .null
            }
        }
    #endif
}
