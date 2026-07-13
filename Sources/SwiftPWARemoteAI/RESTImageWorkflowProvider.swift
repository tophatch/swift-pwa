import Foundation
import SwiftPWACore

/// **Prototype / exploration** — a single, *declarative* `AIWorkflowProvider` that
/// adapts to an arbitrary JSON image API from a descriptor, instead of a
/// hand-written Swift conformance per service. The descriptor (``RESTImageAPISpec``)
/// **travels in the call** (in `config.graph`, the same "the spec is data" idea the
/// ComfyUI runner uses for a node graph), so a running web app can point this at
/// Imagen, an OpenAI-compatible endpoint, Google's Gemini image model
/// ("nano banana"), etc. with no rebuild — only a new descriptor.
///
/// Scope of this prototype (`.oneShot` JSON APIs):
/// - **Auth / endpoint** come from the `AIConnection` (`baseURL` + headers; a
///   `secretRef` resolved into `${secret}` server-side). Nothing API-key-shaped
///   lives in the descriptor.
/// - **Request** is a JSON *template* (``RESTImageAPISpec/body``) with `${key}`
///   placeholders bound from the run's `inputs` (and the endpoint string too, so
///   `/models/${model}:predict` works). An exact `"${key}"` node is replaced by the
///   typed value; an unresolved optional placeholder drops its object key.
/// - **Response** images are pulled by a tiny JSONPath (`a[*].b.c`): an
///   `imagesPath` to the image-bearing nodes, then a relative `dataField`
///   (base64 or URL) + optional `mimeField`. Nodes missing the field are skipped
///   (so Gemini's text parts are ignored automatically).
///
/// Deliberately **not** covered yet (tracked in the write-up): async submit→poll
/// APIs (Qwen native), multipart edits (OpenAI `/images/edits`), per-step progress
/// (cloud image APIs don't stream it), and *conditional* parameter coupling (e.g.
/// Imagen's "a seed forces `sampleCount:1` + `addWatermark:false`") which a flat
/// template can't express. Those keep the hand-written ``RemoteImageProvider`` seam
/// as an escape hatch.
public struct RESTImageWorkflowProvider: AIWorkflowProvider {
    public let providerID: String

    public init(providerID: String = "rest") {
        self.providerID = providerID
    }

    // MARK: - AIWorkflowProvider

    public func describeInputs(
        config: AIWorkflowConfig,
        client _: any NetworkClient
    ) async throws -> AIInputSchema {
        let spec = try Self.decodeSpec(config.graph)
        // Fixed schema, always from the descriptor (no network probe).
        return AIInputSchema(inputs: spec.fields, degraded: false)
    }

    public func runWorkflow(
        config: AIWorkflowConfig,
        client: any NetworkClient
    ) -> AsyncThrowingStream<AIRunEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let events = try await run(config: config, client: client)
                    for event in events { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        config: AIWorkflowConfig,
        client: any NetworkClient
    ) async throws -> [AIRunEvent] {
        let spec = try Self.decodeSpec(config.graph)

        // Resolve inputs → typed values (seed randomization, image → base64).
        var echoSeed: Int?
        let values = Self.resolveValues(spec: spec, inputs: config.inputs, echoSeed: &echoSeed)

        // Build the request from the template + endpoint.
        let endpoint = Self.interpolate(spec.endpoint, values)
        guard let url = Self.makeURL(base: config.connection.baseURL, endpoint: endpoint) else {
            throw AIError.generationFailed("REST provider: invalid endpoint \(endpoint)")
        }
        let boundBody = Self.bind(spec.body, values: values)
        let body = try boundBody.encoded()
        var headers = config.connection.headers
        headers["Content-Type"] = spec.contentType

        let response = try await client.send(NetRequest(
            method: spec.method, url: url, headers: headers, body: body, timeout: 120
        ))

        let json = (try? JSONValue.decode(response.body)) ?? .null
        guard response.isSuccess else {
            let message = spec.errorPath.flatMap { Self.stringValue(at: $0, in: json) }
                ?? String(decoding: response.body.prefix(400), as: UTF8.self)
            throw AIError.generationFailed("REST provider HTTP \(response.status): \(message)")
        }

        // Extract images by path; fetch URLs / decode base64.
        var events: [AIRunEvent] = [.progress(stage: "running")]
        let nodes = Self.nodes(at: spec.output.imagesPath, in: json)
        var index = 0
        for node in nodes {
            let dataString = spec.output.dataField.flatMap { Self.stringValue(at: $0, in: node) }
                ?? node.stringValue
            guard let dataString else { continue } // e.g. a text-only part — skip
            let mime = spec.output.mimeField.flatMap { Self.stringValue(at: $0, in: node) } ?? "image/png"
            let bytes: Data
            switch spec.output.kind {
            case .base64:
                guard let decoded = Data(base64Encoded: dataString) else { continue }
                bytes = decoded
            case .url:
                guard let imageURL = URL(string: dataString) else { continue }
                let imageResponse = try await client.send(NetRequest(method: "GET", url: imageURL, timeout: 120))
                guard imageResponse.isSuccess else { continue }
                bytes = imageResponse.body
            }
            let image = try RemoteImageOutput.make(
                bytes: bytes, mimeType: mime, seed: echoSeed,
                outputDirectory: config.outputDirectory, index: index
            )
            events.append(.image(image))
            index += 1
        }
        guard index > 0 else {
            throw AIError.generationFailed("REST provider: no images at path '\(spec.output.imagesPath)'")
        }
        events.append(.done)
        return events
    }

    // MARK: - Spec

    private static func decodeSpec(_ graph: Data?) throws -> RESTImageAPISpec {
        guard let graph else {
            throw AIError.generationFailed("REST provider needs an API descriptor (in the call's graph/spec)")
        }
        do {
            return try JSONDecoder().decode(RESTImageAPISpec.self, from: graph)
        } catch {
            throw AIError.generationFailed("REST provider: invalid API descriptor — \(error)")
        }
    }

    // MARK: - Value resolution

    private static func resolveValues(
        spec: RESTImageAPISpec, inputs: [String: JSONValue], echoSeed: inout Int?
    ) -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for field in spec.fields {
            let raw = inputs[field.key]
            switch field.type {
            case .seed:
                if case let .number(n)? = raw {
                    echoSeed = Int(n); values[field.key] = .number(n)
                } else {
                    let seed = Int.random(in: 0 ... Int(UInt32.max))
                    echoSeed = seed; values[field.key] = .number(Double(seed))
                }
            case .image, .mask:
                if let base64 = imageBase64(raw) { values[field.key] = .string(base64) }
            // else: no image supplied → omit (placeholder drops out)
            default:
                // Caller's value, else the field's advertised default (so an
                // un-overridden `${model}` etc. still resolves), else omit.
                if let raw, raw != .null { values[field.key] = raw }
                else if let fallback = field.value, fallback != .null { values[field.key] = fallback }
            }
        }
        return values
    }

    /// Pull base64 bytes from a `{ dataBase64 }` / `{ path }` input value.
    private static func imageBase64(_ value: JSONValue?) -> String? {
        guard case let .object(object)? = value else { return nil }
        if case let .string(base64)? = object["dataBase64"], !base64.isEmpty { return base64 }
        if case let .string(path)? = object["path"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        {
            return data.base64EncodedString()
        }
        return nil
    }

    // MARK: - Template binding

    /// Bind `${key}` placeholders in a JSON template. An exact `"${key}"` string
    /// node becomes the typed value; an object entry whose exact placeholder is
    /// unresolved is dropped (so optional params default server-side); other
    /// strings get `${key}` substring interpolation.
    static func bind(_ template: JSONValue, values: [String: JSONValue]) -> JSONValue {
        switch template {
        case let .string(string):
            if let key = exactPlaceholder(string) { return values[key] ?? .null }
            return .string(interpolate(string, values))
        case let .array(array):
            return .array(array.map { bind($0, values: values) })
        case let .object(object):
            var out: [String: JSONValue] = [:]
            for (key, value) in object {
                if case let .string(string) = value, let placeholder = exactPlaceholder(string) {
                    guard let resolved = values[placeholder] else { continue } // drop unresolved optional
                    out[key] = resolved
                } else {
                    out[key] = bind(value, values: values)
                }
            }
            return .object(out)
        default:
            return template
        }
    }

    /// `"${key}"` (and nothing else) → `"key"`; otherwise nil.
    private static func exactPlaceholder(_ string: String) -> String? {
        guard string.hasPrefix("${"), string.hasSuffix("}") else { return nil }
        let inner = string.dropFirst(2).dropLast()
        guard !inner.isEmpty, !inner.contains("$"), !inner.contains("{") else { return nil }
        return String(inner)
    }

    /// Replace every `${key}` substring with the value's string form.
    static func interpolate(_ string: String, _ values: [String: JSONValue]) -> String {
        var result = string
        for (key, value) in values {
            result = result.replacingOccurrences(of: "${\(key)}", with: value.stringForInterpolation)
        }
        return result
    }

    // MARK: - JSONPath (subset: `a.b[*].c`, `a[0]`)

    /// Nodes selected by a dotted path with `[*]` (each array element) / `[n]`.
    static func nodes(at path: String, in root: JSONValue) -> [JSONValue] {
        var current = [root]
        for rawSegment in path.split(separator: ".") {
            let (key, selector) = parseSegment(String(rawSegment))
            var next: [JSONValue] = []
            for node in current {
                guard case let .object(object) = node, let child = object[key] else { continue }
                switch selector {
                case .none:
                    next.append(child)
                case .all:
                    if case let .array(array) = child { next.append(contentsOf: array) }
                case let .index(i):
                    if case let .array(array) = child, i >= 0, i < array.count { next.append(array[i]) }
                }
            }
            current = next
        }
        return current
    }

    /// A single string at a dotted (no `[*]`) relative path.
    static func stringValue(at path: String, in root: JSONValue) -> String? {
        var current = root
        for rawSegment in path.split(separator: ".") {
            let (key, selector) = parseSegment(String(rawSegment))
            guard case let .object(object) = current, let child = object[key] else { return nil }
            switch selector {
            case .none: current = child
            case let .index(i):
                guard case let .array(array) = child, i >= 0, i < array.count else { return nil }
                current = array[i]
            case .all: return nil // not meaningful for a single value
            }
        }
        return current.stringValue
    }

    private enum Selector { case none, all, index(Int) }

    private static func parseSegment(_ segment: String) -> (key: String, selector: Selector) {
        guard let open = segment.firstIndex(of: "["), segment.hasSuffix("]") else {
            return (segment, .none)
        }
        let key = String(segment[..<open])
        let inside = segment[segment.index(after: open) ..< segment.index(before: segment.endIndex)]
        if inside == "*" { return (key, .all) }
        if let i = Int(inside) { return (key, .index(i)) }
        return (key, .none)
    }

    private static func makeURL(base: URL, endpoint: String) -> URL? {
        // String-concatenate so a segment like `:predict` / `:generateContent`
        // isn't percent-escaped by appendPathComponent.
        var origin = base.absoluteString
        while origin.hasSuffix("/") { origin.removeLast() }
        let path = endpoint.hasPrefix("/") ? endpoint : "/" + endpoint
        return URL(string: origin + path)
    }
}

// MARK: - Descriptor

/// A declarative description of a JSON image API — the payload that lets one
/// provider adapt to many services. `Codable`, so it round-trips through the
/// `ai.run` / `ai.describeInputs` call (carried in `config.graph`) or ships as a
/// preset. See ``RESTImageWorkflowProvider``.
public struct RESTImageAPISpec: Codable, Sendable, Equatable {
    /// Path appended to the connection's `baseURL`; may contain `${key}`
    /// placeholders (e.g. `"/models/${model}:predict"`).
    public var endpoint: String
    public var method: String
    public var contentType: String
    /// Request-body JSON template with `${key}` placeholders bound from the run's
    /// inputs. An exact `"${key}"` node becomes the typed value; an unresolved
    /// optional placeholder drops its object key.
    public var body: JSONValue
    public var output: Output
    /// Dotted path to a human error message in a failure response (e.g.
    /// `"error.message"`), for a clearer thrown error.
    public var errorPath: String?
    /// The overridable inputs — doubles as the `describeInputs` schema *and* the
    /// set of `${key}` placeholders the template binds. A `.seed` field with no
    /// value is randomized (and echoed); an `.image`/`.mask` field resolves its
    /// `{ dataBase64 }` / `{ path }` to base64.
    public var fields: [AIInputField]

    public init(
        endpoint: String, method: String = "POST", contentType: String = "application/json",
        body: JSONValue, output: Output, errorPath: String? = nil, fields: [AIInputField]
    ) {
        self.endpoint = endpoint
        self.method = method
        self.contentType = contentType
        self.body = body
        self.output = output
        self.errorPath = errorPath
        self.fields = fields
    }

    /// Where the produced images are in the response, and how they're carried.
    public struct Output: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case base64, url }
        public var kind: Kind
        /// JSONPath to the image-bearing nodes (use `[*]` to iterate an array),
        /// e.g. `"predictions[*]"`, `"data[*]"`, `"candidates[*].content.parts[*]"`.
        public var imagesPath: String
        /// Relative dotted path to the base64/URL string within each node; `nil`
        /// when the node itself is the string.
        public var dataField: String?
        /// Relative dotted path to the MIME type within each node (optional).
        public var mimeField: String?

        public init(kind: Kind, imagesPath: String, dataField: String? = nil, mimeField: String? = nil) {
            self.kind = kind
            self.imagesPath = imagesPath
            self.dataField = dataField
            self.mimeField = mimeField
        }
    }
}

private extension JSONValue {
    var stringValue: String? {
        if case let .string(string) = self { return string }
        return nil
    }

    /// String form for `${key}` substring interpolation (integral numbers lose
    /// the trailing `.0`).
    var stringForInterpolation: String {
        switch self {
        case let .string(string): string
        case let .number(number): number == number.rounded() ? String(Int(number)) : String(number)
        case let .bool(bool): String(bool)
        default: ""
        }
    }
}
