import Foundation
import SwiftPWACore

/// A declarative description of a JSON image API — the payload that lets one
/// ``RESTImageProvider`` adapt to many services. `Codable`, so it round-trips
/// through the `ai.run` / `ai.describeInputs` call (carried in `config.graph`) or
/// ships as a preset (see the factory methods below).
public struct RESTImageAPISpec: Codable, Sendable, Equatable {
    /// Path appended to the connection's `baseURL`; may contain `${key}`
    /// placeholders (e.g. `"/models/${model}:predict"`).
    public var endpoint: String
    public var method: String
    public var contentType: String
    /// Static request headers from the descriptor (merged over the connection's),
    /// for non-secret API-shape headers like `X-DashScope-Async: enable`.
    public var headers: [String: String]?
    /// JSON request-body template with `${key}` placeholders. Mutually exclusive
    /// with ``multipart``.
    public var body: JSONValue?
    /// Multipart form parts (image/mask files + text) — for edit endpoints.
    /// Takes precedence over ``body`` when present.
    public var multipart: [MultipartPart]?
    /// One-shot (default) or async submit → poll.
    public var flow: Flow
    public var output: Output
    /// Dotted path to a human error message in a failure response.
    public var errorPath: String?
    /// The overridable inputs — the `describeInputs` schema *and* the `${key}`
    /// placeholder set. A `.seed` field with no value is randomized (+ echoed);
    /// an `.image`/`.mask` field resolves its `{ dataBase64 }` / `{ path }` to
    /// base64; any other field falls back to its advertised `value` default.
    public var fields: [AIInputField]

    public init(
        endpoint: String, method: String = "POST", contentType: String = "application/json",
        headers: [String: String]? = nil, body: JSONValue? = nil,
        multipart: [MultipartPart]? = nil, flow: Flow = Flow(),
        output: Output, errorPath: String? = nil, fields: [AIInputField]
    ) {
        self.endpoint = endpoint
        self.method = method
        self.contentType = contentType
        self.headers = headers
        self.body = body
        self.multipart = multipart
        self.flow = flow
        self.output = output
        self.errorPath = errorPath
        self.fields = fields
    }

    private enum CodingKeys: String, CodingKey {
        case endpoint, method, contentType, headers, body, multipart, flow, output, errorPath, fields
    }

    /// Custom decode so a descriptor may omit the optional keys (method /
    /// contentType / flow / …) — synthesized Decodable would require every one.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        method = try container.decodeIfPresent(String.self, forKey: .method) ?? "POST"
        contentType = try container.decodeIfPresent(String.self, forKey: .contentType) ?? "application/json"
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
        body = try container.decodeIfPresent(JSONValue.self, forKey: .body)
        multipart = try container.decodeIfPresent([MultipartPart].self, forKey: .multipart)
        flow = try container.decodeIfPresent(Flow.self, forKey: .flow) ?? Flow()
        output = try container.decode(Output.self, forKey: .output)
        errorPath = try container.decodeIfPresent(String.self, forKey: .errorPath)
        fields = try container.decode([AIInputField].self, forKey: .fields)
    }

    // MARK: - Nested types

    /// Where the produced images are in the response, and how they're carried.
    public struct Output: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case base64, url }
        public var kind: Kind
        /// JSONPath to the image-bearing nodes (use `[*]` to iterate an array).
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

    /// One multipart form part. A `.text` part interpolates `${key}` in `value`;
    /// a `.file` part's `value` is an exact `${key}` whose resolved image base64
    /// becomes the file bytes.
    public struct MultipartPart: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case text, file }
        public var name: String
        public var kind: Kind
        public var value: String
        public var filename: String?
        public var contentType: String?

        public init(name: String, kind: Kind, value: String, filename: String? = nil, contentType: String? = nil) {
            self.name = name
            self.kind = kind
            self.value = value
            self.filename = filename
            self.contentType = contentType
        }
    }

    /// One-shot, or async submit → poll a task to completion.
    public struct Flow: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case oneShot, asyncPoll }
        public var kind: Kind
        /// asyncPoll: dotted path to the task id in the submit response.
        public var taskIdPath: String?
        /// asyncPoll: poll endpoint template (`${taskId}` substituted).
        public var pollEndpoint: String?
        public var pollMethod: String?
        /// asyncPoll: dotted path to the status string in a poll response.
        public var statusPath: String?
        public var successValues: [String]?
        public var failureValues: [String]?
        public var pollIntervalMs: Int?

        public init(
            kind: Kind = .oneShot, taskIdPath: String? = nil, pollEndpoint: String? = nil,
            pollMethod: String? = nil, statusPath: String? = nil,
            successValues: [String]? = nil, failureValues: [String]? = nil, pollIntervalMs: Int? = nil
        ) {
            self.kind = kind
            self.taskIdPath = taskIdPath
            self.pollEndpoint = pollEndpoint
            self.pollMethod = pollMethod
            self.statusPath = statusPath
            self.successValues = successValues
            self.failureValues = failureValues
            self.pollIntervalMs = pollIntervalMs
        }
    }
}

// MARK: - Presets

public extension RESTImageAPISpec {
    /// Google **Imagen** `:predict` (base `…/v1beta`, header `x-goog-api-key`).
    /// No `seed` field — Imagen couples a seed to `sampleCount:1` +
    /// `addWatermark:false`, which a flat template can't express.
    static func imagen(model: String = "imagen-4.0-generate-001") -> RESTImageAPISpec {
        RESTImageAPISpec(
            endpoint: "/models/${model}:predict",
            body: .object([
                "instances": .array([.object(["prompt": .string("${prompt}")])]),
                "parameters": .object(["sampleCount": .string("${count}"), "aspectRatio": .string("${aspectRatio}")])
            ]),
            output: .init(
                kind: .base64,
                imagesPath: "predictions[*]",
                dataField: "bytesBase64Encoded",
                mimeField: "mimeType"
            ),
            errorPath: "error.message",
            fields: [
                AIInputField(key: "model", label: "Model", type: .enum, value: .string(model)),
                AIInputField(key: "prompt", label: "Prompt", type: .text),
                AIInputField(
                    key: "aspectRatio",
                    label: "Aspect ratio",
                    type: .enum,
                    value: .string("1:1"),
                    options: ["1:1", "3:4", "4:3", "9:16", "16:9"]
                ),
                AIInputField(key: "count", label: "Number of images", type: .int, value: .number(1), min: 1, max: 4)
            ]
        )
    }

    /// **OpenAI-compatible** `/images/generations` (base `…/v1`, header
    /// `Authorization: Bearer …`). Also covers services exposing this dialect
    /// (Qwen/DashScope compat, gateways) — just change the base + key + model.
    static func openAICompatible(model: String = "gpt-image-1") -> RESTImageAPISpec {
        RESTImageAPISpec(
            endpoint: "/images/generations",
            body: .object([
                "model": .string("${model}"), "prompt": .string("${prompt}"),
                "n": .string("${count}"), "size": .string("${size}")
            ]),
            output: .init(kind: .base64, imagesPath: "data[*]", dataField: "b64_json"),
            errorPath: "error.message",
            fields: [
                AIInputField(key: "model", label: "Model", type: .enum, value: .string(model)),
                AIInputField(key: "prompt", label: "Prompt", type: .text),
                AIInputField(key: "count", label: "Number of images", type: .int, value: .number(1), min: 1, max: 10),
                AIInputField(
                    key: "size",
                    label: "Size",
                    type: .enum,
                    value: .string("1024x1024"),
                    options: ["1024x1024", "1536x1024", "1024x1536", "auto"]
                )
            ]
        )
    }

    /// Google **Gemini** image (`:generateContent`, "nano banana"). Same base +
    /// header as ``imagen(model:)``, different request/response shape.
    static func geminiImage(model: String = "gemini-2.5-flash-image") -> RESTImageAPISpec {
        RESTImageAPISpec(
            endpoint: "/models/${model}:generateContent",
            body: .object([
                "contents": .array([.object(["parts": .array([.object(["text": .string("${prompt}")])])])])
            ]),
            output: .init(
                kind: .base64,
                imagesPath: "candidates[*].content.parts[*]",
                dataField: "inlineData.data",
                mimeField: "inlineData.mimeType"
            ),
            errorPath: "error.message",
            fields: [
                AIInputField(key: "model", label: "Model", type: .enum, value: .string(model)),
                AIInputField(key: "prompt", label: "Prompt", type: .text)
            ]
        )
    }

    /// **OpenAI image edits** `/images/edits` (multipart: an input `image`, an
    /// optional `mask`, and a `prompt`). Base `…/v1`, `Authorization: Bearer …`.
    static func openAIEdit(model: String = "gpt-image-1") -> RESTImageAPISpec {
        RESTImageAPISpec(
            endpoint: "/images/edits",
            multipart: [
                .init(name: "image", kind: .file, value: "${image}", filename: "image.png", contentType: "image/png"),
                .init(name: "mask", kind: .file, value: "${mask}", filename: "mask.png", contentType: "image/png"),
                .init(name: "prompt", kind: .text, value: "${prompt}"),
                .init(name: "model", kind: .text, value: "${model}"),
                .init(name: "n", kind: .text, value: "${count}"),
                .init(name: "size", kind: .text, value: "${size}")
            ],
            output: .init(kind: .base64, imagesPath: "data[*]", dataField: "b64_json"),
            errorPath: "error.message",
            fields: [
                AIInputField(key: "model", label: "Model", type: .enum, value: .string(model)),
                AIInputField(key: "prompt", label: "Edit instruction", type: .text),
                AIInputField(key: "image", label: "Image", type: .image, isImage: true),
                AIInputField(key: "mask", label: "Mask", type: .mask, isImage: true),
                AIInputField(key: "count", label: "Number of images", type: .int, value: .number(1), min: 1, max: 10),
                AIInputField(
                    key: "size",
                    label: "Size",
                    type: .enum,
                    value: .string("1024x1024"),
                    options: ["1024x1024", "1536x1024", "1024x1536", "auto"]
                )
            ]
        )
    }

    /// **Qwen / DashScope** native async text→image (`X-DashScope-Async: enable`,
    /// base `…/api/v1`, `Authorization: Bearer …`). Submit returns a task id;
    /// poll `/tasks/{id}` until `SUCCEEDED`; images come back as URLs. The `model`
    /// and the connection's region base must match the account — e.g.
    /// `wan2.2-t2i-flash` on the international base
    /// (`dashscope-intl.aliyuncs.com/api/v1`), or a Beijing-region model on
    /// `dashscope.aliyuncs.com/api/v1`.
    static func qwen(model: String = "wan2.2-t2i-flash", size: String = "1024*1024") -> RESTImageAPISpec {
        RESTImageAPISpec(
            endpoint: "/services/aigc/text2image/image-synthesis",
            headers: ["X-DashScope-Async": "enable"],
            body: .object([
                "model": .string("${model}"),
                "input": .object(["prompt": .string("${prompt}")]),
                "parameters": .object(["n": .string("${count}"), "size": .string("${size}")])
            ]),
            flow: .init(
                kind: .asyncPoll, taskIdPath: "output.task_id",
                pollEndpoint: "/tasks/${taskId}", pollMethod: "GET",
                statusPath: "output.task_status",
                successValues: ["SUCCEEDED"], failureValues: ["FAILED", "CANCELED", "UNKNOWN"]
            ),
            output: .init(kind: .url, imagesPath: "output.results[*]", dataField: "url"),
            errorPath: "message",
            fields: [
                AIInputField(key: "model", label: "Model", type: .enum, value: .string(model)),
                AIInputField(key: "prompt", label: "Prompt", type: .text),
                AIInputField(key: "count", label: "Number of images", type: .int, value: .number(1), min: 1, max: 4),
                AIInputField(
                    key: "size",
                    label: "Size",
                    type: .enum,
                    value: .string(size),
                    options: ["1024*1024", "1280*720", "720*1280"]
                )
            ]
        )
    }
}
