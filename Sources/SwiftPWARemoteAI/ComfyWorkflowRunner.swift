import Foundation
import SwiftPWACore

// The generic ComfyUI workflow runner: run any adopter-supplied API-format graph
// with named inputs (``ComfyUIProvider/runWorkflow``) and introspect its
// overridable inputs (``ComfyUIProvider/inspectWorkflow``), plus the value /
// binding / introspection types and the pure (network-free) binding engine they
// share. The base ``ComfyUIProvider`` (the `RemoteImageProvider` conformance,
// checkpoint discovery, and the `submitAndFetch` choreography this builds on)
// lives in ComfyUIProvider.swift.

// MARK: - Runner entry points

public extension ComfyUIProvider {
    /// Run an **adopter-supplied API-format workflow** (ComfyUI's "Save (API
    /// Format)" export) verbatim, binding `inputs` into it and returning its
    /// output image(s). This is the general primitive behind the provider: the
    /// app owns importing / storing / selecting workflows; the framework owns
    /// executing them. No per-architecture code — any graph the box can run
    /// (Qwen / Flux / edit / …) runs here.
    ///
    /// - Parameters:
    ///   - graph: the API-format graph JSON (`{ "<nodeId>": { class_type, inputs, _meta } }`).
    ///   - inputs: named values to bind — arbitrary, not a fixed prompt/image/seed
    ///     set (see ``WorkflowInputValue``). An input with no resolvable location
    ///     is ignored (a workflow drives only what it exposes).
    ///   - bindings: explicit input→location map (with fan-out via
    ///     ``WorkflowBinding/at(_:)``). Omit an entry to fall back to the **title
    ///     convention**: every node whose `_meta.title` equals the input name is
    ///     bound (its like-named input, else its sole literal input) — so titling
    ///     the nodes in ComfyUI needs zero binding config.
    ///   - outputDirectory: path-vs-base64 output policy (as `AIGenerateImageRequest`).
    ///
    /// `.image` / `.mask` inputs are uploaded to `/upload/image` first and the
    /// returned filename bound into the target `LoadImage`. A `.seed(nil)` gets a
    /// fresh random seed per run; the resolved seed is echoed on the results.
    func runWorkflow(
        graph: Data,
        inputs: [String: WorkflowInputValue],
        bindings: [String: WorkflowBinding] = [:],
        client: any NetworkClient,
        outputDirectory: String? = nil
    ) async throws -> [AIGeneratedImage] {
        guard var graphObj = try JSONSerialization.jsonObject(with: graph) as? [String: Any] else {
            throw AIError.generationFailed("ComfyUI workflow is not a JSON object")
        }
        let runSeed = Int.random(in: 0 ... Int(UInt32.max))
        var echoSeed: Int?
        for (name, value) in inputs {
            let locations = WorkflowGraph.locations(for: name, binding: bindings[name], graph: graphObj)
            guard !locations.isEmpty else { continue } // unbound / unknown input ignored
            let bound: Any
            switch value {
            case let .image(bytes), let .mask(bytes):
                bound = try await uploadImage(bytes: bytes, client: client)
            case let .text(s): bound = s
            case let .int(i): bound = i
            case let .float(d): bound = d
            case let .bool(b): bound = b
            case let .seed(s):
                let resolved = s ?? runSeed
                bound = resolved
                echoSeed = resolved
            case let .raw(j): bound = j.foundationObject
            }
            for location in locations {
                WorkflowGraph.setInput(&graphObj, at: location, value: bound)
            }
        }
        return try await submitAndFetch(
            graph: graphObj,
            seed: echoSeed,
            outputDirectory: outputDirectory,
            client: client
        )
    }

    /// List a workflow's **overridable inputs** so a UI can build controls (and
    /// bindings) automatically instead of the adopter hand-declaring them.
    ///
    /// Combines two sources: the graph's *literal* inputs (widget values —
    /// overridable; `[nodeId, slot]` connection inputs are excluded) crossed with
    /// `GET /object_info` for each node's real type, range (min/max/step), combo
    /// options (sampler names, per-box model file lists), and image flag. Each
    /// result carries its `(nodeID, inputName)` binding location, so a chosen
    /// input becomes a ``WorkflowBinding`` directly.
    ///
    /// Returns *candidates* — a graph has literals a UI shouldn't surface
    /// (internal constants); the app filters. `titledOnly` narrows to nodes the
    /// author tagged with a `_meta.title` (the intended, labelled inputs).
    /// `/object_info` is fetched once per call (not cached across calls).
    func inspectWorkflow(
        graph: Data,
        client: any NetworkClient,
        titledOnly: Bool = false
    ) async throws -> [WorkflowInput] {
        guard let graphObj = try JSONSerialization.jsonObject(with: graph) as? [String: Any] else {
            throw AIError.generationFailed("ComfyUI workflow is not a JSON object")
        }
        let objectInfo = try await fetchObjectInfo(client: client)
        return WorkflowGraph.overridableInputs(graph: graphObj, objectInfo: objectInfo, titledOnly: titledOnly)
    }
}

private extension ComfyUIProvider {
    /// Upload raw image bytes to `POST /upload/image` (multipart), returning the
    /// server filename to bind into a `LoadImage` node (prefixed with its
    /// subfolder when the server nests it).
    func uploadImage(bytes: Data, client: any NetworkClient) async throws -> String {
        // Keep the boundary under RFC 2046's 70-char limit — a longer one (e.g.
        // clientID + a UUID) makes aiohttp (ComfyUI's server) 500 on the upload.
        let boundary = "----swiftpwa-\(UUID().uuidString)"
        let filename = "swift-pwa-\(UUID().uuidString).png"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(bytes)
        append("\r\n--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue\r\n")
        append("--\(boundary)--\r\n")

        let response = try await client.send(NetRequest(
            method: "POST",
            url: baseURL.appendingPathComponent("upload").appendingPathComponent("image"),
            headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"],
            body: body,
            timeout: 120
        ))
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let name = json["name"] as? String
        else {
            let message = String(decoding: response.body.prefix(300), as: UTF8.self)
            throw AIError.generationFailed("ComfyUI /upload/image HTTP \(response.status): \(message)")
        }
        let subfolder = json["subfolder"] as? String ?? ""
        return subfolder.isEmpty ? name : "\(subfolder)/\(name)"
    }

    /// The full `GET /object_info` node catalog (class → spec), for introspection.
    func fetchObjectInfo(client: any NetworkClient) async throws -> [String: Any] {
        let url = baseURL.appendingPathComponent("object_info")
        let response = try await client.send(NetRequest(url: url, timeout: 60))
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else {
            throw AIError.generationFailed("ComfyUI /object_info HTTP \(response.status)")
        }
        return json
    }
}

// MARK: - Named input values

/// A value bound into a workflow at one or more node-input locations by
/// ``ComfyUIProvider/runWorkflow(graph:inputs:bindings:client:outputDirectory:)``.
///
/// Inputs are **arbitrary and open** — the runner doesn't privilege
/// `prompt`/`image`/`seed`; any named input a workflow exposes (`steps`, `cfg`,
/// `denoise`, `width`, a model filename for a picker node, …) is just an entry
/// in the `inputs` map. The bound set *is* the "overridable from the UI"
/// whitelist. `.raw` is the escape hatch for anything a node input wants that
/// the typed cases don't cover.
public enum WorkflowInputValue: Sendable, Equatable {
    case text(String)
    case int(Int)
    case float(Double)
    case bool(Bool)
    /// A seed with ComfyUI's randomize-on-`nil` policy: `.seed(nil)` gets a
    /// fresh random seed **per run** (so a graph with a baked seed doesn't
    /// return the identical image every call), `.seed(x)` pins it. When fanned
    /// out to several nodes the *same* resolved seed lands in each.
    case seed(Int?)
    /// A source image to upload via `/upload/image` before binding; the
    /// returned server filename is what's written into the target `LoadImage`
    /// node. (Phase B.)
    case image(Data)
    /// An edit/inpaint mask, uploaded like ``image``. (Phase B.)
    case mask(Data)
    /// Any JSON value, written verbatim — for exotic node inputs the typed
    /// cases don't model. Integral numbers are written as integers.
    case raw(JSONValue)

    /// Whether this value must be uploaded (image/mask) rather than written
    /// inline. Drives both binding (upload → filename) and the title-convention
    /// default for `isImage`.
    var isUpload: Bool {
        switch self {
        case .image, .mask: true
        default: false
        }
    }
}

// MARK: - Bindings

/// Where a named input's value is written in the graph — a **list** of
/// node-input locations, so one logical input fans out to every node that uses
/// it (e.g. a `width` referenced by an `EmptyLatentImage` *and* an upscale node
/// moves together from a single control).
///
/// Construct with ``at(node:input:)`` / ``at(_:)`` for scalar/string inputs and
/// ``imageAt(node:input:)`` / ``imageAt(_:)`` for image/mask inputs (which the
/// runner uploads first). When no explicit binding is given for an input, the
/// runner falls back to the **title convention** (see
/// ``ComfyUIProvider/runWorkflow(graph:inputs:bindings:client:outputDirectory:)``).
public struct WorkflowBinding: Sendable, Equatable {
    public struct Location: Sendable, Equatable, Hashable {
        public var nodeID: String
        public var input: String
        public init(nodeID: String, input: String) {
            self.nodeID = nodeID
            self.input = input
        }
    }

    public var locations: [Location]
    /// Marks the target(s) as an image/mask input, so the runner uploads the
    /// bytes and binds the returned filename. Set by ``imageAt(node:input:)``.
    public var isImage: Bool

    public init(locations: [Location], isImage: Bool = false) {
        self.locations = locations
        self.isImage = isImage
    }

    /// A single scalar/string location.
    public static func at(node: String, input: String) -> WorkflowBinding {
        WorkflowBinding(locations: [Location(nodeID: node, input: input)])
    }

    /// Several scalar/string locations — one input fanned out to all of them.
    public static func at(_ locations: [(node: String, input: String)]) -> WorkflowBinding {
        WorkflowBinding(locations: locations.map { Location(nodeID: $0.node, input: $0.input) })
    }

    /// A single image/mask location (uploaded before binding).
    public static func imageAt(node: String, input: String) -> WorkflowBinding {
        WorkflowBinding(locations: [Location(nodeID: node, input: input)], isImage: true)
    }

    /// Several image/mask locations sharing one uploaded file.
    public static func imageAt(_ locations: [(node: String, input: String)]) -> WorkflowBinding {
        WorkflowBinding(locations: locations.map { Location(nodeID: $0.node, input: $0.input) }, isImage: true)
    }
}

// MARK: - Introspection

/// One overridable input discovered by
/// ``ComfyUIProvider/inspectWorkflow(graph:client:titledOnly:)``: a node's
/// *literal* (widget) input, enriched from `/object_info` with its real type,
/// range, and combo options.
///
/// Each carries its `(nodeID, inputName)` — a binding location — so a UI turns a
/// user-chosen input straight into a ``WorkflowBinding`` + value without a
/// hand-written map. `title` is the node's `_meta.title` (the friendly label the
/// author intended); absent it, a UI falls back to `"\(nodeClass) #\(nodeID) · \(inputName)"`.
public struct WorkflowInput: Sendable, Equatable {
    public var nodeID: String
    public var nodeClass: String
    public var title: String?
    public var inputName: String
    /// The `/object_info` type string: `INT` / `FLOAT` / `STRING` / `BOOLEAN`,
    /// `COMBO` for an enum/model-file list, or `nil` if `/object_info` had no
    /// entry for this node/input.
    public var type: String?
    /// The graph's current (widget) value for this input.
    public var currentValue: JSONValue
    public var min: Double?
    public var max: Double?
    public var step: Double?
    /// Combo choices (sampler names, schedulers, per-box model file lists, …).
    public var options: [String]?
    /// The input takes an image (an `IMAGE`-typed input or an upload widget like
    /// `LoadImage.image`), so a UI offers a file picker and a binding should be
    /// an `.imageAt`.
    public var isImage: Bool

    public init(
        nodeID: String, nodeClass: String, title: String?, inputName: String,
        type: String?, currentValue: JSONValue,
        min: Double? = nil, max: Double? = nil, step: Double? = nil,
        options: [String]? = nil, isImage: Bool = false
    ) {
        self.nodeID = nodeID
        self.nodeClass = nodeClass
        self.title = title
        self.inputName = inputName
        self.type = type
        self.currentValue = currentValue
        self.min = min
        self.max = max
        self.step = step
        self.options = options
        self.isImage = isImage
    }
}

// MARK: - Binding engine (pure graph manipulation, no network / instance state)

enum WorkflowGraph {
    /// A node-input value is a **connection** (wired from another node's output)
    /// iff it's a `[nodeId, slotIndex]` array; anything else is a **literal**
    /// (widget) value the runner may override. Only literals are bindable /
    /// introspectable.
    static func isConnection(_ value: Any) -> Bool {
        value is [Any] || value is NSArray
    }

    /// The literal (bindable) input keys of a node, in a stable sorted order.
    static func literalInputs(of node: [String: Any]) -> [String] {
        guard let inputs = node["inputs"] as? [String: Any] else { return [] }
        return inputs.filter { !isConnection($0.value) }.keys.sorted()
    }

    static func title(of node: [String: Any]) -> String? {
        (node["_meta"] as? [String: Any])?["title"] as? String
    }

    /// Resolve where a named input lands, honoring an explicit `binding` if
    /// present, otherwise the **title convention**: every node whose
    /// `_meta.title` equals `name` contributes a location — the node input keyed
    /// `name` if it has one (e.g. a `KSampler` titled `seed` → its `seed`
    /// input), else its sole literal input (e.g. a `CLIPTextEncode` titled
    /// `prompt` → its one literal `text`), else nothing (ambiguous → needs an
    /// explicit binding).
    static func locations(
        for name: String,
        binding: WorkflowBinding?,
        graph: [String: Any]
    ) -> [WorkflowBinding.Location] {
        if let binding { return binding.locations }
        var found: [WorkflowBinding.Location] = []
        for (nodeID, raw) in graph {
            guard let node = raw as? [String: Any], title(of: node) == name else { continue }
            let literals = literalInputs(of: node)
            if literals.contains(name) {
                found.append(.init(nodeID: nodeID, input: name))
            } else if literals.count == 1 {
                found.append(.init(nodeID: nodeID, input: literals[0]))
            }
            // else: multiple literals, none named `name` → ambiguous, skip.
        }
        // Deterministic order (dictionaries are unordered) so fan-out is stable.
        return found.sorted { ($0.nodeID, $0.input) < ($1.nodeID, $1.input) }
    }

    /// Set `graph[nodeID].inputs[input] = value`, creating nothing that isn't
    /// already there (an unknown node/input is skipped — a workflow drives only
    /// the inputs it exposes).
    static func setInput(_ graph: inout [String: Any], at location: WorkflowBinding.Location, value: Any) {
        guard var node = graph[location.nodeID] as? [String: Any],
              var inputs = node["inputs"] as? [String: Any]
        else { return }
        inputs[location.input] = value
        node["inputs"] = inputs
        graph[location.nodeID] = node
    }

    /// Sort key that orders `"2"` before `"10"` (numeric node ids first, then
    /// lexical) so introspection / fan-out output is stable and human-natural.
    private static func nodeOrder(_ id: String, _ input: String) -> (Int, String, String) {
        (Int(id) ?? Int.max, id, input)
    }

    /// Build the overridable-input list: every node's literal inputs, enriched
    /// from `/object_info`. Pure — the network fetch is the caller's.
    static func overridableInputs(
        graph: [String: Any],
        objectInfo: [String: Any],
        titledOnly: Bool
    ) -> [WorkflowInput] {
        var result: [WorkflowInput] = []
        for (nodeID, raw) in graph {
            guard let node = raw as? [String: Any],
                  let classType = node["class_type"] as? String,
                  let inputs = node["inputs"] as? [String: Any] else { continue }
            let title = title(of: node)
            if titledOnly, title == nil { continue }
            let classSpec = objectInfo[classType] as? [String: Any]
            for (inputName, value) in inputs where !isConnection(value) {
                var input = WorkflowInput(
                    nodeID: nodeID, nodeClass: classType, title: title, inputName: inputName,
                    type: nil, currentValue: JSONValue.from(foundation: value)
                )
                enrich(&input, classSpec: classSpec)
                result.append(input)
            }
        }
        return result.sorted {
            nodeOrder($0.nodeID, $0.inputName) < nodeOrder($1.nodeID, $1.inputName)
        }
    }

    /// Enrich a discovered input from its node's `/object_info` spec: the input's
    /// declared type / combo options / numeric range / image flag. A `nil`
    /// `classSpec` (node absent from `/object_info`) leaves the graph-derived
    /// fields as-is.
    private static func enrich(_ input: inout WorkflowInput, classSpec: [String: Any]?) {
        guard let inputSpec = inputDescriptor(in: classSpec, named: input.inputName) else { return }
        // Spec is `[typeOrOptions, metaDict?]`: a String type, or an array of
        // combo options.
        if let typeString = inputSpec.first as? String {
            input.type = typeString
            if typeString == "IMAGE" { input.isImage = true }
        } else if let options = inputSpec.first as? [Any] {
            input.type = "COMBO"
            input.options = options.compactMap { $0 as? String }
        }
        guard let meta = inputSpec.count > 1 ? inputSpec[1] as? [String: Any] : nil else { return }
        input.min = (meta["min"] as? NSNumber)?.doubleValue
        input.max = (meta["max"] as? NSNumber)?.doubleValue
        input.step = (meta["step"] as? NSNumber)?.doubleValue
        if meta["image_upload"] as? Bool == true { input.isImage = true }
    }

    /// Find an input's descriptor (`[type, meta?]`) under a class's
    /// `input.required` or `input.optional`.
    private static func inputDescriptor(in classSpec: [String: Any]?, named name: String) -> [Any]? {
        guard let inputBlock = classSpec?["input"] as? [String: Any] else { return nil }
        for group in ["required", "optional"] {
            if let groupSpec = inputBlock[group] as? [String: Any], let descriptor = groupSpec[name] as? [Any] {
                return descriptor
            }
        }
        return nil
    }
}

// MARK: - JSON <-> Foundation bridging

extension JSONValue {
    /// Losslessly read a `JSONSerialization` value (from a parsed graph /
    /// `/object_info`) into a `JSONValue`, resolving the `NSNumber` bool-vs-number
    /// ambiguity via `JSONValue`'s own decode. Not on a hot path.
    static func from(foundation any: Any) -> JSONValue {
        if any is NSNull { return .null }
        guard let data = try? JSONSerialization.data(withJSONObject: ["v": any]),
              case let .object(dict)? = try? JSONValue.decode(data),
              let value = dict["v"]
        else { return .null }
        return value
    }

    /// Convert to a `JSONSerialization`-compatible Foundation value. Integral
    /// numbers become `Int` (ComfyUI seed/steps inputs want integers, not
    /// `7.0`).
    var foundationObject: Any {
        switch self {
        case .null: NSNull()
        case let .bool(b): b
        case let .number(n): n == n.rounded() && abs(n) < 9.007e15 ? Int(n) : n
        case let .string(s): s
        case let .array(a): a.map(\.foundationObject)
        case let .object(o): o.mapValues(\.foundationObject)
        }
    }
}
