import Foundation
import SwiftPWACore

/// The ComfyUI conformance of the runtime, JS-reachable ``AIWorkflowProvider``
/// (`ai.run` / `ai.describeInputs`). **Stateless w.r.t. the endpoint** — the
/// connection travels in every call (`config.connection`), so one instance
/// serves any number of user-entered ComfyUI boxes without a rebuild.
///
/// Reuses the v0.8.9 runner's pure binding engine (`WorkflowGraph`) and output
/// plumbing (`RemoteImageOutput`); adds a connection-parameterized job
/// choreography with **coarse progress** (queued → running → done, polled from
/// `/prompt` + `/history` — the HTTP-only tier; per-step `/ws` progress is a
/// follow-up) and **cancellation** via `POST /interrupt` on stream teardown.
///
/// Schema field keys are `"<nodeID>/<inputName>"`, so a run's `inputs` map
/// straight back to node-input locations — no title convention needed for the
/// JS path, and no separate bindings for the common case.
public struct ComfyUIWorkflowProvider: AIWorkflowProvider {
    public let providerID = "comfyui"

    private let clientID: String
    private let pollInterval: Duration
    private let timeout: Duration

    public init(
        clientID: String = UUID().uuidString,
        pollInterval: Duration = .milliseconds(600),
        timeout: Duration = .seconds(600)
    ) {
        self.clientID = clientID
        self.pollInterval = pollInterval
        self.timeout = timeout
    }

    // MARK: - describeInputs

    public func describeInputs(
        config: AIWorkflowConfig,
        client: any NetworkClient
    ) async throws -> AIInputSchema {
        guard let graphData = config.graph,
              let graph = try JSONSerialization.jsonObject(with: graphData) as? [String: Any]
        else {
            throw AIError.generationFailed("ComfyUI describeInputs needs an API-format graph")
        }
        // Cross with the live catalog; degrade to a graph-only schema if the box
        // is unreachable (so a pasted graph is authorable before the box is up).
        var objectInfo: [String: Any] = [:]
        var degraded = false
        do {
            objectInfo = try await fetchObjectInfo(config.connection, client: client)
        } catch {
            degraded = true
        }
        let fields = WorkflowGraph
            .overridableInputs(graph: graph, objectInfo: objectInfo, titledOnly: config.titledOnly)
            .map(Self.field(from:))
        return AIInputSchema(inputs: fields, degraded: degraded)
    }

    private static func field(from input: WorkflowInput) -> AIInputField {
        let label = input.title ?? "\(input.nodeClass) #\(input.nodeID) · \(input.inputName)"
        return AIInputField(
            key: "\(input.nodeID)/\(input.inputName)",
            label: label,
            type: kind(for: input),
            value: input.currentValue,
            min: input.min, max: input.max, step: input.step,
            options: input.options,
            group: input.nodeClass,
            isImage: input.isImage
        )
    }

    private static func kind(for input: WorkflowInput) -> AIInputField.Kind {
        if input.isImage { return input.inputName.lowercased().contains("mask") ? .mask : .image }
        if input.inputName == "seed" || input.inputName == "noise_seed" { return .seed }
        switch input.type {
        case "INT": return .int
        case "FLOAT": return .float
        case "BOOLEAN": return .bool
        case "STRING": return .text
        case "COMBO": return .enum
        default: break
        }
        switch input.currentValue { // no /object_info entry → infer from the widget value
        case .bool: return .bool
        case let .number(n): return n == n.rounded() ? .int : .float
        default: return .text
        }
    }

    // MARK: - runWorkflow

    public func runWorkflow(
        config: AIWorkflowConfig,
        client: any NetworkClient
    ) -> AsyncThrowingStream<AIRunEvent, any Error> {
        AsyncThrowingStream { continuation in
            let promptBox = PromptBox()
            let connection = config.connection
            let task = Task {
                do {
                    try await run(config: config, client: client, promptBox: promptBox) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                // Cancel the in-flight ComfyUI job too (unsubscribe / window close).
                if let promptID = promptBox.value {
                    Task { try? await Self.interrupt(promptID, connection, client) }
                }
            }
        }
    }

    private func run(
        config: AIWorkflowConfig,
        client: any NetworkClient,
        promptBox: PromptBox,
        emit: @escaping @Sendable (AIRunEvent) -> Void
    ) async throws {
        guard let graphData = config.graph,
              var graph = try JSONSerialization.jsonObject(with: graphData) as? [String: Any]
        else {
            throw AIError.generationFailed("ComfyUI run needs an API-format graph")
        }

        // Pass 1 (async): upload any image/mask inputs → filenames. Keeps the
        // non-Sendable graph dict out of the await that follows.
        var uploaded: [String: String] = [:]
        for (key, value) in config.inputs where Self.imageBytes(value) != nil {
            let bytes = Self.imageBytes(value)!
            uploaded[key] = try await uploadImage(bytes, config.connection, client: client)
        }

        // Pass 2 (sync): bind every input into the graph by its "<node>/<input>"
        // key; track the resolved seed to echo on results.
        let runSeed = Int.random(in: 0 ... Int(UInt32.max))
        var echoSeed: Int?
        for (key, value) in config.inputs {
            guard let location = Self.location(for: key) else { continue }
            let bound: Any
            if let filename = uploaded[key] {
                bound = filename
            } else if Self.isSeed(key), case .null = value {
                bound = runSeed; echoSeed = runSeed
            } else if Self.isSeed(key), case let .number(n) = value {
                bound = Int(n); echoSeed = Int(n)
            } else if let coerced = Self.coerce(value) {
                bound = coerced
            } else {
                continue
            }
            WorkflowGraph.setInput(&graph, at: location, value: bound)
        }

        let promptBody = try JSONSerialization.data(withJSONObject: ["prompt": graph, "client_id": clientID])

        // Submit.
        emit(.progress(stage: "queued"))
        let queued = try await send(
            "prompt", method: "POST",
            body: promptBody, contentType: "application/json",
            connection: config.connection, client: client
        )
        guard queued.isSuccess,
              let promptID = (try? JSONSerialization.jsonObject(with: queued.body) as? [String: Any])?["prompt_id"]
              as? String
        else {
            let message = String(decoding: queued.body.prefix(500), as: UTF8.self)
            throw AIError.generationFailed("ComfyUI /prompt HTTP \(queued.status): \(message)")
        }
        promptBox.value = promptID

        // Per-step progress via /ws (best-effort). A client without a WebSocket
        // transport (e.g. AndroidNetworkClient) inherits the throwing default and
        // this task exits quietly — the coarse /queue "running" signal still fires.
        let progressTask = Task {
            await streamProgress(promptID: promptID, connection: config.connection, client: client, emit: emit)
        }
        defer { progressTask.cancel() }

        // Poll /history (coarse progress via /prompt queue), then fetch outputs.
        let refs = try await poll(promptID: promptID, connection: config.connection, client: client, emit: emit)
        progressTask.cancel()

        for (index, ref) in refs.enumerated() {
            try Task.checkCancellation()
            let bytes = try await fetchView(ref, connection: config.connection, client: client)
            let mime = ref.mime
            let image = try RemoteImageOutput.make(
                bytes: bytes, mimeType: mime, seed: echoSeed,
                outputDirectory: config.outputDirectory, index: index
            )
            let dims = Self.pngDimensions(bytes)
            emit(.image(image, width: dims?.width, height: dims?.height))
        }
        emit(.done)
    }

    // MARK: - Per-step progress (/ws)

    /// Open ComfyUI's `/ws` and translate `progress` frames (`value`/`max`) into
    /// fine `.progress` events for our prompt. Best-effort: any failure (no
    /// WebSocket transport, socket drop) is swallowed — coarse polling covers it.
    private func streamProgress(
        promptID: String,
        connection: AIConnection,
        client: any NetworkClient,
        emit: @Sendable (AIRunEvent) -> Void
    ) async {
        guard let url = Self.webSocketURL(connection.baseURL, clientID: clientID) else { return }
        do {
            for try await frame in client.openWebSocket(NetWebSocketRequest(url: url, headers: connection.headers)) {
                guard case let .text(text) = frame,
                      let data = text.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["type"] as? String == "progress",
                      let payload = json["data"] as? [String: Any]
                else { continue }
                // Frames may omit prompt_id on older servers; when present, filter.
                if let pid = payload["prompt_id"] as? String, pid != promptID { continue }
                emit(.progress(
                    stage: "running",
                    value: (payload["value"] as? NSNumber)?.doubleValue,
                    max: (payload["max"] as? NSNumber)?.doubleValue
                ))
            }
        } catch {
            // Best-effort — coarse /queue polling remains the floor.
        }
    }

    /// The `/ws?clientId=…` URL for a connection (http→ws, https→wss).
    private static func webSocketURL(_ base: URL, clientID: String) -> URL? {
        var components = URLComponents(url: base.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)
        let secure = components?.scheme == "https"
        components?.scheme = secure ? "wss" : "ws"
        components?.queryItems = [URLQueryItem(name: "clientId", value: clientID)]
        return components?.url
    }

    // MARK: - Polling (coarse progress)

    private struct OutputRef { let filename: String; let subfolder: String; let type: String; let mime: String }

    private func poll(
        promptID: String,
        connection: AIConnection,
        client: any NetworkClient,
        emit: @Sendable (AIRunEvent) -> Void
    ) async throws -> [OutputRef] {
        let deadline = ContinuousClock.now + timeout
        var announcedRunning = false
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            // Coarse "running" signal: the prompt left the pending queue.
            if !announcedRunning, try await isRunning(promptID, connection: connection, client: client) {
                announcedRunning = true
                emit(.progress(stage: "running"))
            }
            if let refs = try await historyOutputs(promptID, connection: connection, client: client) {
                return refs
            }
            try await Task.sleep(for: pollInterval)
        }
        throw AIError.generationFailed("ComfyUI generation timed out after \(timeout)")
    }

    private func isRunning(
        _ promptID: String, connection: AIConnection, client: any NetworkClient
    ) async throws -> Bool {
        // Queue state is at `/queue` (`{queue_running, queue_pending}`); `/prompt`
        // returns only `exec_info.queue_remaining`.
        let response = try await send("queue", connection: connection, client: client)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let running = json["queue_running"] as? [[Any]]
        else { return false }
        // Each running entry is `[number, prompt_id, graph, …]`.
        return running.contains { entry in entry.count > 1 && (entry[1] as? String) == promptID }
    }

    private func historyOutputs(
        _ promptID: String, connection: AIConnection, client: any NetworkClient
    ) async throws -> [OutputRef]? {
        let response = try await send("history/\(promptID)", connection: connection, client: client)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let entry = json[promptID] as? [String: Any],
              let outputs = entry["outputs"] as? [String: Any]
        else { return nil }
        var refs: [OutputRef] = []
        for (_, node) in outputs {
            guard let node = node as? [String: Any], let images = node["images"] as? [[String: Any]] else { continue }
            for image in images {
                guard let filename = image["filename"] as? String else { continue }
                refs.append(OutputRef(
                    filename: filename,
                    subfolder: image["subfolder"] as? String ?? "",
                    type: image["type"] as? String ?? "output",
                    mime: "image/png"
                ))
            }
        }
        return refs.isEmpty ? nil : refs
    }

    // MARK: - Connection-parameterized HTTP

    private func send(
        _ path: String, method: String = "GET",
        body: Data? = nil, contentType: String? = nil,
        query: [URLQueryItem] = [],
        connection: AIConnection, client: any NetworkClient
    ) async throws -> NetResponse {
        var url = connection.baseURL
        for component in path.split(separator: "/") { url.appendPathComponent(String(component)) }
        if !query.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = query
            if let resolved = components?.url { url = resolved }
        }
        var headers = connection.headers
        if let contentType { headers["Content-Type"] = contentType }
        return try await client.send(NetRequest(method: method, url: url, headers: headers, body: body, timeout: 60))
    }

    private func fetchView(
        _ ref: OutputRef, connection: AIConnection, client: any NetworkClient
    ) async throws -> Data {
        let response = try await send(
            "view",
            query: [
                URLQueryItem(name: "filename", value: ref.filename),
                URLQueryItem(name: "subfolder", value: ref.subfolder),
                URLQueryItem(name: "type", value: ref.type)
            ],
            connection: connection, client: client
        )
        guard response.isSuccess else {
            throw AIError.generationFailed("ComfyUI /view HTTP \(response.status) for \(ref.filename)")
        }
        return response.body
    }

    private func fetchObjectInfo(
        _ connection: AIConnection, client: any NetworkClient
    ) async throws -> [String: Any] {
        let response = try await send("object_info", connection: connection, client: client)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else {
            throw AIError.generationFailed("ComfyUI /object_info HTTP \(response.status)")
        }
        return json
    }

    private func uploadImage(
        _ bytes: Data, _ connection: AIConnection, client: any NetworkClient
    ) async throws -> String {
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

        let response = try await send(
            "upload/image", method: "POST",
            body: body, contentType: "multipart/form-data; boundary=\(boundary)",
            connection: connection, client: client
        )
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

    private static func interrupt(
        _ promptID: String, _ connection: AIConnection, _ client: any NetworkClient
    ) async throws {
        // Stop the running job; also drop it from the queue if still pending.
        _ = try? await client.send(NetRequest(
            method: "POST", url: connection.baseURL.appendingPathComponent("interrupt"),
            headers: connection.headers, timeout: 15
        ))
        let deleteBody = try? JSONSerialization.data(withJSONObject: ["delete": [promptID]])
        var headers = connection.headers
        headers["Content-Type"] = "application/json"
        _ = try? await client.send(NetRequest(
            method: "POST", url: connection.baseURL.appendingPathComponent("queue"),
            headers: headers, body: deleteBody, timeout: 15
        ))
    }

    // MARK: - Input coercion + helpers

    private static func location(for key: String) -> WorkflowBinding.Location? {
        guard let slash = key.firstIndex(of: "/") else { return nil }
        let nodeID = String(key[..<slash])
        let input = String(key[key.index(after: slash)...])
        guard !nodeID.isEmpty, !input.isEmpty else { return nil }
        return WorkflowBinding.Location(nodeID: nodeID, input: input)
    }

    private static func isSeed(_ key: String) -> Bool {
        let input = key.split(separator: "/").last.map(String.init) ?? ""
        return input == "seed" || input == "noise_seed"
    }

    /// Extract raw image bytes from a `{ dataBase64 }` / `{ path }` input value.
    private static func imageBytes(_ value: JSONValue) -> Data? {
        guard case let .object(object) = value else { return nil }
        if case let .string(base64)? = object["dataBase64"], let data = Data(base64Encoded: base64) {
            return data
        }
        if case let .string(path)? = object["path"], let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            return data
        }
        return nil
    }

    /// Coerce a scalar JSON value to a `JSONSerialization`-compatible node value.
    private static func coerce(_ value: JSONValue) -> Any? {
        switch value {
        case let .string(string): string
        case let .bool(bool): bool
        case let .number(number): number == number.rounded() && abs(number) < 9.007e15 ? Int(number) : number
        case .null: nil
        case .array, .object: value.foundationObject
        }
    }

    /// Read a PNG's pixel dimensions from its IHDR (bytes 16..24), for the
    /// `.image` event's `width`/`height` echo. `nil` for non-PNG.
    private static func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        guard data.count >= 24, Array(data.prefix(4)) == signature else { return nil }
        func be32(_ offset: Int) -> Int {
            let bytes = data[data.startIndex.advanced(by: offset) ..< data.startIndex.advanced(by: offset + 4)]
            return bytes.reduce(0) { ($0 << 8) | Int($1) }
        }
        return (be32(16), be32(20))
    }
}

/// A `Sendable` box holding the in-flight ComfyUI `prompt_id` so the stream's
/// `onTermination` can interrupt the job it doesn't otherwise have a handle to.
private final class PromptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
