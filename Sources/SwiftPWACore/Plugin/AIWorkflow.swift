import Foundation

// The runtime, JS-reachable workflow contract (`ai.run` / `ai.describeInputs`).
// Provider-agnostic and generic (no ComfyUI types) so it lives in Core beside
// the rest of `ai.*`; a provider such as ComfyUI conforms in its own target.
// See docs/proposals/runtime-workflow-plugin.md.

/// How to reach a provider — **travels in the call**, so one registered provider
/// serves any number of user-entered endpoints without a rebuild.
public struct AIConnection: Sendable, Equatable, Codable {
    /// The provider origin, e.g. `http://my-nas.local:8188`.
    public var baseURL: URL
    /// Extra request headers — an open bag (reverse-proxy tokens, custom auth).
    /// A header value containing the literal `${secret}` has it substituted with
    /// the resolved ``secretRef`` (so key material never enters JS).
    public var headers: [String: String]
    /// A `secrets.*` key resolved **server-side** (never in JS) just before the
    /// request; its value replaces `${secret}` in ``headers``.
    public var secretRef: String?

    public init(baseURL: URL, headers: [String: String] = [:], secretRef: String? = nil) {
        self.baseURL = baseURL
        self.headers = headers
        self.secretRef = secretRef
    }

    private enum CodingKeys: String, CodingKey { case baseURL, headers, secretRef }

    /// Custom decode so JS may omit `headers` / `secretRef` (synthesized Decodable
    /// would require every key).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decode(URL.self, forKey: .baseURL)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        secretRef = try container.decodeIfPresent(String.self, forKey: .secretRef)
    }
}

/// One overridable input a provider accepts, for building a UI control. Produced
/// by ``AIWorkflowProvider/describeInputs(config:client:)``; the app renders by
/// `label`/`type` and sends run values keyed by ``key`` (an opaque handle the
/// provider understands — for graph providers, the node-input location).
public struct AIInputField: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case text, int, float, bool, `enum`, image, mask, seed
    }

    /// Opaque handle the provider maps back to its knob. For ComfyUI this is
    /// `"<nodeID>/<inputName>"`, so the run needn't carry node ids separately.
    public var key: String
    /// Friendly label (a node title, else a derived `class #id · input`).
    public var label: String?
    public var type: Kind
    /// The graph's current / default value.
    public var value: JSONValue?
    public var min: Double?
    public var max: Double?
    public var step: Double?
    /// Combo choices (sampler names, per-box model-file lists).
    public var options: [String]?
    /// A grouping hint (e.g. the node class), for sectioned UIs.
    public var group: String?
    public var isImage: Bool

    public init(
        key: String, label: String? = nil, type: Kind, value: JSONValue? = nil,
        min: Double? = nil, max: Double? = nil, step: Double? = nil,
        options: [String]? = nil, group: String? = nil, isImage: Bool = false
    ) {
        self.key = key
        self.label = label
        self.type = type
        self.value = value
        self.min = min
        self.max = max
        self.step = step
        self.options = options
        self.group = group
        self.isImage = isImage
    }
}

/// The overridable-input list for a provider/graph. `degraded` is `true` when it
/// came from a graph-only fallback (the connection was unreachable, so types are
/// widget-derived and ranges / combo options are absent).
public struct AIInputSchema: Sendable, Codable, Equatable {
    public var inputs: [AIInputField]
    public var degraded: Bool

    public init(inputs: [AIInputField], degraded: Bool = false) {
        self.inputs = inputs
        self.degraded = degraded
    }
}

/// A streaming `ai.run` event. Encodes to `{ type, … }` for JS. `image` echoes
/// the resolved seed (+ dimensions where known) so reproducibility survives the
/// bridge.
public struct AIRunEvent: Sendable, Encodable, Equatable {
    public enum Kind: String, Sendable, Encodable {
        case progress, image, done
    }

    public var type: Kind
    /// progress: a coarse stage (`"queued"` / `"running"`) or a node id.
    public var stage: String?
    /// progress: per-step value / max when a provider can report it (nil for
    /// the HTTP-only coarse tier).
    public var value: Double?
    public var max: Double?
    /// image: the produced image (`dataBase64` | `path`, `mimeType`, `seed`).
    public var image: AIGeneratedImage?
    public var width: Int?
    public var height: Int?
    /// A provider job handle (ComfyUI's `prompt_id`), emitted once the job is
    /// submitted so the app can **recover** — re-issue `ai.run` with this id
    /// (via ``AIWorkflowConfig/jobId``) to re-attach to a run whose stream was
    /// torn down (e.g. the app was backgrounded) instead of starting over.
    public var jobId: String?

    public static func progress(
        stage: String, value: Double? = nil, max: Double? = nil, jobId: String? = nil
    ) -> AIRunEvent {
        AIRunEvent(type: .progress, stage: stage, value: value, max: max, jobId: jobId)
    }

    public static func image(_ image: AIGeneratedImage, width: Int? = nil, height: Int? = nil) -> AIRunEvent {
        AIRunEvent(type: .image, image: image, width: width, height: height)
    }

    public static let done = AIRunEvent(type: .done)

    private init(
        type: Kind, stage: String? = nil, value: Double? = nil, max: Double? = nil,
        image: AIGeneratedImage? = nil, width: Int? = nil, height: Int? = nil, jobId: String? = nil
    ) {
        self.type = type
        self.stage = stage
        self.value = value
        self.max = max
        self.image = image
        self.width = width
        self.height = height
        self.jobId = jobId
    }
}

/// Everything a run/introspect call carries — provider-agnostic. `inputs` are raw
/// JSON keyed by the schema's `key`; the provider coerces them to its own value
/// types. `graph` is present only for graph-based providers.
public struct AIWorkflowConfig: Sendable {
    public var connection: AIConnection
    public var graph: Data?
    public var inputs: [String: JSONValue]
    public var titledOnly: Bool
    public var outputDirectory: String?
    /// **Recovery:** an existing provider job handle to re-attach to instead of
    /// submitting a new job. When set, a provider skips submission and resumes
    /// the identified job — streaming its remaining progress if still running,
    /// or returning its outputs if already finished (see ``AIRunEvent/jobId``).
    /// `graph`/`inputs` are unused in this case.
    public var jobId: String?

    public init(
        connection: AIConnection, graph: Data? = nil,
        inputs: [String: JSONValue] = [:], titledOnly: Bool = false,
        outputDirectory: String? = nil, jobId: String? = nil
    ) {
        self.connection = connection
        self.graph = graph
        self.inputs = inputs
        self.titledOnly = titledOnly
        self.outputDirectory = outputDirectory
        self.jobId = jobId
    }
}

/// The seam a runtime, JS-reachable image provider implements — stateless w.r.t.
/// the endpoint (the connection is in every call). ComfyUI conforms in
/// `SwiftPWARemoteAI`; other providers (fixed-schema cloud / on-device) can too.
public protocol AIWorkflowProvider: Sendable {
    /// A stable id the `ai.run` / `ai.describeInputs` calls route on (e.g.
    /// `"comfyui"`).
    var providerID: String { get }

    /// List the overridable inputs for a (graph, connection). Graph-based
    /// providers cross the graph with the connection's catalog; a fixed provider
    /// returns its static schema. Should degrade to a graph-only schema when the
    /// connection is unreachable (`AIInputSchema.degraded`).
    func describeInputs(config: AIWorkflowConfig, client: any NetworkClient) async throws -> AIInputSchema

    /// Run and stream `.progress` → `.image`(s) → `.done`. Cancellation is via
    /// the stream's termination (unsubscribe / window close) — a provider that
    /// has a server-side interrupt issues it there.
    func runWorkflow(config: AIWorkflowConfig, client: any NetworkClient)
        -> AsyncThrowingStream<AIRunEvent, any Error>
}
