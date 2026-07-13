import Foundation
import SwiftPWACore

/// A single, **declarative** image provider that adapts to an arbitrary JSON
/// image API from a ``RESTImageAPISpec`` descriptor — instead of a hand-written
/// Swift conformance per service. It serves **both** surfaces:
///
/// - **Runtime** (``AIWorkflowProvider`` — `ai.run` / `ai.describeInputs`): the
///   descriptor **travels in the call** (in `config.graph`), so a web app can
///   point it at a new API with no rebuild. Construct `RESTImageProvider()` (a
///   generic pass-through) or `RESTImageProvider(providerID:spec:)` to pin a
///   preset while still taking the endpoint/auth from the call's connection.
/// - **Fixed** (``RemoteImageProvider`` — `ai.generateImage`, the
///   `MultiModelImageBackend` switcher): construct with a held `spec` + injected
///   `baseURL` + `auth` + `models`. Standard request fields map onto the
///   descriptor by convention (`prompt` / `negativePrompt` / `seed` / `count` /
///   `image` / `mask` / `model`).
///
/// What a descriptor parameterizes (see ``RESTImageAPISpec``):
/// - **Auth / endpoint** — from the `AIConnection` (baseURL + headers, a
///   `secretRef` resolved into `${secret}` server-side). No key material in the
///   descriptor.
/// - **Request** — a JSON template with `${key}` placeholders, **or** a multipart
///   form (image/mask file parts + text parts) for edit endpoints.
/// - **Flow** — one-shot, **or** async submit → poll a task until it succeeds
///   (job APIs like Qwen/DashScope).
/// - **Response** — a tiny JSONPath (`a[*].b.c`) to the image nodes + a relative
///   `dataField` (base64 or URL) + optional `mimeField`. Nodes missing the field
///   are skipped (so Gemini's interleaved text parts are ignored for free).
///
/// Presets ship as data: ``RESTImageAPISpec/imagen(model:)``,
/// ``RESTImageAPISpec/openAICompatible(model:)``, ``RESTImageAPISpec/geminiImage(model:)``,
/// ``RESTImageAPISpec/openAIEdit(model:)``, ``RESTImageAPISpec/qwen(model:size:)``.
public struct RESTImageProvider: AIWorkflowProvider, RemoteImageProvider {
    public let providerID: String
    public let backendID: String
    public let models: [AIModelInfo]

    private let heldSpec: RESTImageAPISpec?
    private let fixedBaseURL: String?
    private let auth: (@Sendable () async -> [String: String])?
    private let pollTimeout: Duration

    /// Generic runtime provider: the descriptor + connection travel in each
    /// `ai.run` / `ai.describeInputs` call (`config.graph`).
    public init(providerID: String = "rest", pollTimeout: Duration = .seconds(300)) {
        self.providerID = providerID
        backendID = providerID
        models = []
        heldSpec = nil
        fixedBaseURL = nil
        auth = nil
        self.pollTimeout = pollTimeout
    }

    /// Preset runtime provider: a descriptor is pinned (so `describeInputs` needs
    /// no `graph`), while the endpoint + auth still come from the call's
    /// connection (e.g. a `secretRef` for the key).
    public init(providerID: String, spec: RESTImageAPISpec, pollTimeout: Duration = .seconds(300)) {
        self.providerID = providerID
        backendID = providerID
        models = []
        heldSpec = spec
        fixedBaseURL = nil
        auth = nil
        self.pollTimeout = pollTimeout
    }

    /// Fixed `ai.generateImage` provider (drops into `MultiModelImageBackend`):
    /// a held descriptor + an injected endpoint, auth headers, and model catalog.
    public init(
        backendID: String,
        models: [AIModelInfo],
        spec: RESTImageAPISpec,
        baseURL: String,
        auth: @escaping @Sendable () async -> [String: String],
        pollTimeout: Duration = .seconds(300)
    ) {
        providerID = backendID
        self.backendID = backendID
        self.models = models
        heldSpec = spec
        fixedBaseURL = baseURL
        self.auth = auth
        self.pollTimeout = pollTimeout
    }

    // MARK: - AIWorkflowProvider (ai.run / ai.describeInputs)

    public func describeInputs(
        config: AIWorkflowConfig,
        client _: any NetworkClient
    ) async throws -> AIInputSchema {
        let spec = try resolveSpec(config.graph)
        return AIInputSchema(inputs: spec.fields, degraded: false)
    }

    public func runWorkflow(
        config: AIWorkflowConfig,
        client: any NetworkClient
    ) -> AsyncThrowingStream<AIRunEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let spec = try resolveSpec(config.graph)
                    try await run(
                        spec: spec, connection: config.connection, inputs: config.inputs,
                        outputDirectory: config.outputDirectory, client: client
                    ) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - RemoteImageProvider (ai.generateImage)

    public func generateImage(
        _ request: AIGenerateImageRequest,
        client: any NetworkClient
    ) async throws -> [AIGeneratedImage] {
        guard let spec = heldSpec, let base = fixedBaseURL, let baseURL = URL(string: base) else {
            throw AIError.generationFailed("RESTImageProvider: generateImage needs a fixed spec + baseURL")
        }
        let connection = await AIConnection(baseURL: baseURL, headers: auth?() ?? [:])
        let box = ImageBox()
        try await run(
            spec: spec, connection: connection, inputs: Self.inputs(from: request),
            outputDirectory: request.outputDirectory, client: client
        ) { event in if let image = event.image { box.append(image) } }
        return box.images
    }

    /// Map a standard request onto descriptor field keys by convention.
    private static func inputs(from request: AIGenerateImageRequest) -> [String: JSONValue] {
        var inputs: [String: JSONValue] = [:]
        if let prompt = request.prompt { inputs["prompt"] = .string(prompt) }
        if let negative = request.negativePrompt { inputs["negativePrompt"] = .string(negative) }
        if let seed = request.seed { inputs["seed"] = .number(Double(seed)) }
        if let count = request.count { inputs["count"] = .number(Double(count)) }
        if let model = request.model { inputs["model"] = .string(model) }
        if let image = request.image { inputs["image"] = imageValue(image) }
        if let mask = request.mask { inputs["mask"] = imageValue(mask) }
        return inputs
    }

    private static func imageValue(_ image: AIImage) -> JSONValue {
        var object: [String: JSONValue] = [:]
        if let base64 = image.dataBase64 { object["dataBase64"] = .string(base64) }
        if let path = image.path { object["path"] = .string(path) }
        return .object(object)
    }

    // MARK: - Core engine (shared by both surfaces)

    private func resolveSpec(_ graph: Data?) throws -> RESTImageAPISpec {
        if let heldSpec { return heldSpec }
        guard let graph else {
            throw AIError.generationFailed("RESTImageProvider needs an API descriptor (held or in the call's graph)")
        }
        do {
            return try JSONDecoder().decode(RESTImageAPISpec.self, from: graph)
        } catch {
            throw AIError.generationFailed("RESTImageProvider: invalid API descriptor — \(error)")
        }
    }

    private func run(
        spec: RESTImageAPISpec,
        connection: AIConnection,
        inputs: [String: JSONValue],
        outputDirectory: String?,
        client: any NetworkClient,
        emit: @Sendable (AIRunEvent) -> Void
    ) async throws {
        var echoSeed: Int?
        let values = Self.resolveValues(spec: spec, inputs: inputs, echoSeed: &echoSeed)

        // Submit.
        let submitJSON = try await send(
            spec: spec, endpoint: spec.endpoint, method: spec.method,
            values: values, connection: connection, client: client, forSubmit: true
        )

        // Resolve to the body the images come from: the submit response (one-shot)
        // or the final poll body (async job).
        let resultJSON: JSONValue
        switch spec.flow.kind {
        case .oneShot:
            emit(.progress(stage: "running"))
            resultJSON = submitJSON
        case .asyncPoll:
            resultJSON = try await poll(
                spec: spec, submit: submitJSON, connection: connection, client: client, emit: emit
            )
        }

        // Extract images.
        var index = 0
        for node in Self.nodes(at: spec.output.imagesPath, in: resultJSON) {
            try Task.checkCancellation()
            let dataString = spec.output.dataField.flatMap { Self.stringValue(at: $0, in: node) } ?? node.stringValue
            guard let dataString else { continue }
            let mime = spec.output.mimeField.flatMap { Self.stringValue(at: $0, in: node) } ?? "image/png"
            let bytes: Data
            switch spec.output.kind {
            case .base64:
                guard let decoded = Data(base64Encoded: dataString) else { continue }
                bytes = decoded
            case .url:
                guard let url = URL(string: dataString) else { continue }
                let response = try await client.send(NetRequest(method: "GET", url: url, timeout: 120))
                guard response.isSuccess else { continue }
                bytes = response.body
            }
            let image = try RemoteImageOutput.make(
                bytes: bytes, mimeType: mime, seed: echoSeed, outputDirectory: outputDirectory, index: index
            )
            emit(.image(image))
            index += 1
        }
        guard index > 0 else {
            throw AIError.generationFailed("RESTImageProvider: no images at path '\(spec.output.imagesPath)'")
        }
        emit(.done)
    }

    /// Poll an async job until its status reaches a success (or failure) value,
    /// emitting each status change as coarse progress. Returns the final body.
    private func poll(
        spec: RESTImageAPISpec,
        submit: JSONValue,
        connection: AIConnection,
        client: any NetworkClient,
        emit: @Sendable (AIRunEvent) -> Void
    ) async throws -> JSONValue {
        guard let taskIdPath = spec.flow.taskIdPath,
              let taskId = Self.stringValue(at: taskIdPath, in: submit),
              let pollEndpoint = spec.flow.pollEndpoint,
              let statusPath = spec.flow.statusPath
        else {
            throw AIError.generationFailed("RESTImageProvider: asyncPoll needs taskIdPath / pollEndpoint / statusPath")
        }
        let success = Set(spec.flow.successValues ?? ["SUCCEEDED"])
        let failure = Set(spec.flow.failureValues ?? [])
        let interval = Duration.milliseconds(spec.flow.pollIntervalMs ?? 1500)
        let deadline = ContinuousClock.now + pollTimeout
        var lastStatus = ""
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let body = try await send(
                spec: spec, endpoint: Self.interpolate(pollEndpoint, ["taskId": .string(taskId)]),
                method: spec.flow.pollMethod ?? "GET", values: [:],
                connection: connection, client: client, forSubmit: false
            )
            let status = Self.stringValue(at: statusPath, in: body) ?? ""
            if status != lastStatus { lastStatus = status; emit(.progress(stage: status.lowercased())) }
            if success.contains(status) { return body }
            if failure.contains(status) {
                throw AIError.generationFailed("RESTImageProvider: job \(taskId) failed with status \(status)")
            }
            try await Task.sleep(for: interval)
        }
        throw AIError.generationFailed("RESTImageProvider: job timed out after \(pollTimeout)")
    }

    /// Build (JSON or multipart) + send one request; parse the response, throwing
    /// a descriptor-aware error on a non-2xx.
    private func send(
        spec: RESTImageAPISpec, endpoint: String, method: String,
        values: [String: JSONValue], connection: AIConnection,
        client: any NetworkClient, forSubmit: Bool
    ) async throws -> JSONValue {
        let interpolatedEndpoint = Self.interpolate(endpoint, values)
        guard let url = Self.makeURL(base: connection.baseURL, endpoint: interpolatedEndpoint) else {
            throw AIError.generationFailed("RESTImageProvider: invalid endpoint \(interpolatedEndpoint)")
        }
        var headers = connection.headers
        for (key, value) in spec.headers ?? [:] { headers[key] = value }

        var body: Data?
        if forSubmit {
            if let parts = spec.multipart {
                let boundary = "----swiftpwa-\(UUID().uuidString)" // ≤70 chars (RFC 2046)
                headers["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
                body = Self.multipartBody(parts: parts, values: values, boundary: boundary)
            } else if let template = spec.body {
                headers["Content-Type"] = spec.contentType
                body = try Self.bind(template, values: values).encoded()
            }
        }

        let response = try await client.send(NetRequest(
            method: method, url: url, headers: headers, body: body, timeout: 120
        ))
        let json = (try? JSONValue.decode(response.body)) ?? .null
        guard response.isSuccess else {
            let message = spec.errorPath.flatMap { Self.stringValue(at: $0, in: json) }
                ?? String(decoding: response.body.prefix(400), as: UTF8.self)
            throw AIError.generationFailed("RESTImageProvider HTTP \(response.status): \(message)")
        }
        return json
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
                if case let .number(number)? = raw {
                    echoSeed = Int(number); values[field.key] = .number(number)
                } else {
                    let seed = Int.random(in: 0 ... Int(UInt32.max))
                    echoSeed = seed; values[field.key] = .number(Double(seed))
                }
            case .image, .mask:
                if let base64 = imageBase64(raw) { values[field.key] = .string(base64) }
            default:
                if let raw, raw != .null { values[field.key] = raw }
                else if let fallback = field.value, fallback != .null { values[field.key] = fallback }
            }
        }
        return values
    }

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

    // MARK: - Multipart

    private static func multipartBody(
        parts: [RESTImageAPISpec.MultipartPart], values: [String: JSONValue], boundary: String
    ) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for part in parts {
            switch part.kind {
            case .text:
                // A text part whose value is an exact `${key}` placeholder that
                // didn't resolve is omitted; a literal or interpolated one is kept.
                if let key = exactPlaceholder(part.value), values[key] == nil { continue }
                let text = interpolate(part.value, values)
                append("--\(boundary)\r\n")
                append("Content-Disposition: form-data; name=\"\(part.name)\"\r\n\r\n")
                append("\(text)\r\n")
            case .file:
                guard let key = exactPlaceholder(part.value),
                      case let .string(base64)? = values[key],
                      let bytes = Data(base64Encoded: base64)
                else { continue } // no image supplied → omit the part
                let filename = part.filename ?? "\(part.name).png"
                append("--\(boundary)\r\n")
                append("Content-Disposition: form-data; name=\"\(part.name)\"; filename=\"\(filename)\"\r\n")
                append("Content-Type: \(part.contentType ?? "application/octet-stream")\r\n\r\n")
                body.append(bytes)
                append("\r\n")
            }
        }
        append("--\(boundary)--\r\n")
        return body
    }

    // MARK: - Template binding

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
                    guard let resolved = values[placeholder] else { continue }
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

    private static func exactPlaceholder(_ string: String) -> String? {
        guard string.hasPrefix("${"), string.hasSuffix("}") else { return nil }
        let inner = string.dropFirst(2).dropLast()
        guard !inner.isEmpty, !inner.contains("$"), !inner.contains("{") else { return nil }
        return String(inner)
    }

    static func interpolate(_ string: String, _ values: [String: JSONValue]) -> String {
        var result = string
        for (key, value) in values {
            result = result.replacingOccurrences(of: "${\(key)}", with: value.stringForInterpolation)
        }
        return result
    }

    // MARK: - JSONPath (subset: `a.b[*].c`, `a[0]`)

    static func nodes(at path: String, in root: JSONValue) -> [JSONValue] {
        var current = [root]
        for rawSegment in path.split(separator: ".") {
            let (key, selector) = parseSegment(String(rawSegment))
            var next: [JSONValue] = []
            for node in current {
                guard case let .object(object) = node, let child = object[key] else { continue }
                switch selector {
                case .none: next.append(child)
                case .all: if case let .array(array) = child { next.append(contentsOf: array) }
                case let .index(i): if case let .array(array) = child, i >= 0, i < array.count { next.append(array[i]) }
                }
            }
            current = next
        }
        return current
    }

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
            case .all: return nil
            }
        }
        return current.stringValue
    }

    private enum Selector { case none, all, index(Int) }

    private static func parseSegment(_ segment: String) -> (key: String, selector: Selector) {
        guard let open = segment.firstIndex(of: "["), segment.hasSuffix("]") else { return (segment, .none) }
        let key = String(segment[..<open])
        let inside = segment[segment.index(after: open) ..< segment.index(before: segment.endIndex)]
        if inside == "*" { return (key, .all) }
        if let i = Int(inside) { return (key, .index(i)) }
        return (key, .none)
    }

    private static func makeURL(base: URL, endpoint: String) -> URL? {
        var origin = base.absoluteString
        while origin.hasSuffix("/") { origin.removeLast() }
        let path = endpoint.hasPrefix("/") ? endpoint : "/" + endpoint
        return URL(string: origin + path)
    }
}

/// Collects images from the run's event stream for the unary `generateImage`.
private final class ImageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _images: [AIGeneratedImage] = []
    func append(_ image: AIGeneratedImage) { lock.withLock { _images.append(image) } }
    var images: [AIGeneratedImage] {
        lock.withLock { _images }
    }
}

private extension JSONValue {
    var stringValue: String? {
        if case let .string(string) = self { return string }
        return nil
    }

    var stringForInterpolation: String {
        switch self {
        case let .string(string): string
        case let .number(number): number == number.rounded() ? String(Int(number)) : String(number)
        case let .bool(bool): String(bool)
        default: ""
        }
    }
}
