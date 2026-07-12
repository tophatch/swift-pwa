import Foundation
import SwiftPWACore

/// A ``RemoteImageProvider`` for a **local-network ComfyUI** instance over its
/// raw HTTP API (`POST /prompt` → poll `GET /history/{id}` → `GET /view`).
///
/// ComfyUI is graph-based and bring-your-own-workflow, so the provider takes a
/// ``ComfyWorkflowTemplate`` — an API-format workflow graph plus a set of
/// *patches* mapping request fields (prompt, seed, steps, size, …) onto node
/// inputs. That keeps it general across any workflow, with a turnkey
/// ``ComfyWorkflowTemplate/txt2imgSDXL(checkpoint:)`` for the common case:
///
/// ```swift
/// let comfy = RemoteImageBackend(
///     provider: ComfyUIProvider(
///         baseURL: URL(string: "http://nas.local:8188")!,
///         workflow: .txt2imgSDXL(checkpoint: "sd_xl_base_1.0.safetensors"),
///         models: [.init(id: "comfy-sdxl", label: "ComfyUI (SDXL)",
///                        capabilities: [.imageGeneration], availability: .ready,
///                        offlineCapable: false)]),
///     client: URLSessionNetworkClient())
/// ```
///
/// v1 polls `/history` for completion (no per-step progress); live `/ws`
/// progress is a follow-up. On Android a plain-`http://` LAN endpoint needs the
/// host allow-listed via `android.network.cleartext_domains`.
public struct ComfyUIProvider: RemoteImageProvider {
    public let models: [AIModelInfo]
    public let backendID = "comfyui"

    private let baseURL: URL
    private let workflow: ComfyWorkflowTemplate
    private let clientID: String
    private let pollInterval: Duration
    private let timeout: Duration

    /// - Parameters:
    ///   - baseURL: the ComfyUI origin, e.g. `http://nas.local:8188`.
    ///   - workflow: the graph + patches to run. Defaults to a standard SDXL
    ///     txt2img graph.
    ///   - models: the catalog to advertise (adopter-labelled). Defaults to a
    ///     single "ComfyUI (SDXL)" image-generation entry.
    ///   - clientID: the ComfyUI `client_id`; defaults to a fresh UUID.
    ///   - pollInterval / timeout: how often / how long to poll `/history`.
    public init(
        baseURL: URL,
        workflow: ComfyWorkflowTemplate = .txt2imgSDXL(),
        models: [AIModelInfo] = ComfyUIProvider.defaultModels,
        clientID: String = UUID().uuidString,
        pollInterval: Duration = .milliseconds(600),
        timeout: Duration = .seconds(300)
    ) {
        self.baseURL = baseURL
        self.workflow = workflow
        self.models = models
        self.clientID = clientID
        self.pollInterval = pollInterval
        self.timeout = timeout
    }

    public static let defaultModels: [AIModelInfo] = [
        AIModelInfo(
            id: "comfyui-sdxl",
            label: "ComfyUI (SDXL)",
            capabilities: [.imageGeneration],
            availability: .ready,
            offlineCapable: false
        )
    ]

    public func generateImage(
        _ request: AIGenerateImageRequest,
        client: any NetworkClient
    ) async throws -> [AIGeneratedImage] {
        let seed = request.seed ?? Int.random(in: 0 ... Int(UInt32.max))
        let graph = try workflow.build(request: request, seed: seed)

        // 1. Queue the prompt.
        let promptBody = try JSONSerialization.data(withJSONObject: ["prompt": graph, "client_id": clientID])
        let queued = try await client.send(NetRequest(
            method: "POST",
            url: baseURL.appendingPathComponent("prompt"),
            headers: ["Content-Type": "application/json"],
            body: promptBody,
            timeout: 60
        ))
        guard queued.isSuccess else {
            let message = String(decoding: queued.body.prefix(500), as: UTF8.self)
            throw AIError.generationFailed("ComfyUI /prompt HTTP \(queued.status): \(message)")
        }
        guard let promptID = (try? JSONSerialization.jsonObject(with: queued.body) as? [String: Any])?["prompt_id"]
            as? String
        else {
            throw AIError.generationFailed("ComfyUI /prompt returned no prompt_id")
        }

        // 2. Poll /history until the prompt's outputs appear.
        let outputs = try await pollHistory(promptID: promptID, client: client)

        // 3. Fetch each output image via /view.
        var images: [AIGeneratedImage] = []
        for (index, ref) in outputs.enumerated() {
            var components = URLComponents(url: baseURL.appendingPathComponent("view"), resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "filename", value: ref.filename),
                URLQueryItem(name: "subfolder", value: ref.subfolder),
                URLQueryItem(name: "type", value: ref.type)
            ]
            guard let url = components?.url else { continue }
            let view = try await client.send(NetRequest(url: url, timeout: 60))
            guard view.isSuccess else {
                throw AIError.generationFailed("ComfyUI /view HTTP \(view.status) for \(ref.filename)")
            }
            let mime = view.headers.first { $0.key.lowercased() == "content-type" }?.value ?? "image/png"
            try images.append(RemoteImageOutput.make(
                bytes: view.body,
                mimeType: mime,
                seed: seed,
                request: request,
                index: index
            ))
        }
        guard !images.isEmpty else {
            throw AIError.generationFailed("ComfyUI produced no images (check the workflow's output node)")
        }
        return images
    }

    // MARK: - Polling

    private struct ImageRef { let filename: String; let subfolder: String; let type: String }

    private func pollHistory(promptID: String, client: any NetworkClient) async throws -> [ImageRef] {
        let deadline = ContinuousClock.now + timeout
        let url = baseURL.appendingPathComponent("history").appendingPathComponent(promptID)
        while ContinuousClock.now < deadline {
            let response = try await client.send(NetRequest(url: url, timeout: 30))
            if response.isSuccess,
               let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
               let entry = json[promptID] as? [String: Any],
               let refs = imageRefs(from: entry)
            {
                return refs
            }
            try await Task.sleep(for: pollInterval)
        }
        throw AIError.generationFailed("ComfyUI generation timed out after \(timeout)")
    }

    /// Pull `{filename, subfolder, type}` triples out of a `/history` entry's
    /// `outputs` map. Returns `nil` until outputs (with images) are present, so
    /// polling keeps waiting.
    private func imageRefs(from entry: [String: Any]) -> [ImageRef]? {
        guard let outputs = entry["outputs"] as? [String: Any] else { return nil }
        var refs: [ImageRef] = []
        for (_, node) in outputs {
            guard let node = node as? [String: Any], let images = node["images"] as? [[String: Any]] else { continue }
            for image in images {
                guard let filename = image["filename"] as? String else { continue }
                refs.append(ImageRef(
                    filename: filename,
                    subfolder: image["subfolder"] as? String ?? "",
                    type: image["type"] as? String ?? "output"
                ))
            }
        }
        return refs.isEmpty ? nil : refs
    }
}

// MARK: - Workflow template

/// A ComfyUI workflow to run, expressed as an **API-format** graph (what
/// ComfyUI's "Save (API Format)" exports) plus a set of ``Patch``es mapping
/// request fields onto node inputs — so any workflow works, not just the built-in.
public struct ComfyWorkflowTemplate: Sendable {
    /// The API-format workflow graph as JSON: `{ "<nodeId>": { class_type, inputs } }`.
    public var graphJSON: Data
    /// Where to inject request fields into the graph.
    public var patches: [Patch]

    public init(graphJSON: Data, patches: [Patch]) {
        self.graphJSON = graphJSON
        self.patches = patches
    }

    /// Map one request field onto `graph[nodeID].inputs[input]`. A field that's
    /// absent on the request (e.g. `steps == nil`) is skipped, leaving the
    /// graph's own default.
    public struct Patch: Sendable {
        public var nodeID: String
        public var input: String
        public var field: Field

        public init(nodeID: String, input: String, field: Field) {
            self.nodeID = nodeID
            self.input = input
            self.field = field
        }
    }

    public enum Field: Sendable {
        case prompt, negativePrompt, seed, steps, width, height, count, guidanceScale
    }

    /// Apply the patches to the graph for `request` + `seed`, returning the
    /// mutated graph ready to POST under `{ "prompt": … }`.
    func build(request: AIGenerateImageRequest, seed: Int) throws -> [String: Any] {
        guard var graph = try JSONSerialization.jsonObject(with: graphJSON) as? [String: Any] else {
            throw AIError.generationFailed("ComfyUI workflow template is not a JSON object")
        }
        for patch in patches {
            guard let value = value(for: patch.field, request: request, seed: seed) else { continue }
            guard var node = graph[patch.nodeID] as? [String: Any],
                  var inputs = node["inputs"] as? [String: Any]
            else { continue }
            inputs[patch.input] = value
            node["inputs"] = inputs
            graph[patch.nodeID] = node
        }
        return graph
    }

    private func value(for field: Field, request: AIGenerateImageRequest, seed: Int) -> Any? {
        switch field {
        case .prompt: request.prompt
        case .negativePrompt: request.negativePrompt
        case .seed: seed
        case .steps: request.steps
        case .width: request.width
        case .height: request.height
        case .count: request.count
        case .guidanceScale: request.guidanceScale
        }
    }

    /// A standard SDXL text→image workflow. `checkpoint` is the `.safetensors`
    /// filename as it appears in the ComfyUI instance's checkpoint list — the
    /// one field that must match the target server (default is the common SDXL
    /// base name; override it for your instance).
    public static func txt2imgSDXL(checkpoint: String = "sd_xl_base_1.0.safetensors") -> ComfyWorkflowTemplate {
        let graph = """
        {
          "3": { "class_type": "KSampler", "inputs": {
              "seed": 0, "steps": 25, "cfg": 7.0, "sampler_name": "euler", "scheduler": "normal",
              "denoise": 1.0, "model": ["4", 0], "positive": ["6", 0], "negative": ["7", 0],
              "latent_image": ["5", 0] } },
          "4": { "class_type": "CheckpointLoaderSimple", "inputs": { "ckpt_name": "\(checkpoint)" } },
          "5": { "class_type": "EmptyLatentImage", "inputs": { "width": 1024, "height": 1024, "batch_size": 1 } },
          "6": { "class_type": "CLIPTextEncode", "inputs": { "text": "", "clip": ["4", 1] } },
          "7": { "class_type": "CLIPTextEncode", "inputs": { "text": "", "clip": ["4", 1] } },
          "8": { "class_type": "VAEDecode", "inputs": { "samples": ["3", 0], "vae": ["4", 2] } },
          "9": { "class_type": "SaveImage", "inputs": { "filename_prefix": "swift-pwa", "images": ["8", 0] } }
        }
        """
        return ComfyWorkflowTemplate(
            graphJSON: Data(graph.utf8),
            patches: [
                Patch(nodeID: "6", input: "text", field: .prompt),
                Patch(nodeID: "7", input: "text", field: .negativePrompt),
                Patch(nodeID: "3", input: "seed", field: .seed),
                Patch(nodeID: "3", input: "steps", field: .steps),
                Patch(nodeID: "3", input: "cfg", field: .guidanceScale),
                Patch(nodeID: "5", input: "width", field: .width),
                Patch(nodeID: "5", input: "height", field: .height),
                Patch(nodeID: "5", input: "batch_size", field: .count)
            ]
        )
    }
}
