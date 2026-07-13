import Foundation
import SwiftPWACore

/// A ``RemoteImageProvider`` for **Google Imagen** (v3 / v4) over the Gemini API
/// REST surface — the simplest auth path (an API key, no OAuth). Wrap it in a
/// ``RemoteImageBackend`` and drop it into a `MultiModelImageBackend` next to
/// your on-device models:
///
/// ```swift
/// let imagen = RemoteImageBackend(
///     provider: ImagenProvider(apiKey: { await keychain.googleAIKey() }),
///     client: URLSessionNetworkClient()
/// )
/// ```
///
/// **The API key is injected, never stored by swift-pwa** — the closure is read
/// on each request, so the adopter owns storage / rotation. A `nil` key surfaces
/// as `AIError.generationFailed` at generate time (Imagen models advertise
/// `.ready`, since the key can't be probed cheaply).
///
/// Endpoint: `POST {base}/models/{model}:predict`, header `x-goog-api-key`, body
/// `{ instances: [{ prompt }], parameters: { sampleCount, aspectRatio, … } }`,
/// response `{ predictions: [{ bytesBase64Encoded, mimeType }] }`.
public struct ImagenProvider: RemoteImageProvider {
    /// Default catalog — the stable Gemini-API Imagen ids. Override via `init`.
    public static let defaultModels: [AIModelInfo] = [
        model(id: "imagen-4.0-generate-001", label: "Imagen 4"),
        model(id: "imagen-3.0-generate-002", label: "Imagen 3")
    ]

    public let models: [AIModelInfo]
    public let backendID = "google-imagen"

    private let apiKey: @Sendable () async -> String?
    private let baseURL: String

    /// - Parameters:
    ///   - apiKey: read on each request; `nil` ⇒ a clear generate-time error.
    ///   - models: the Imagen variants to advertise / route among (their `id`s
    ///     are the API model ids). Defaults to Imagen 4 + Imagen 3.
    ///   - baseURL: the Gemini API base. Defaults to the public endpoint.
    public init(
        apiKey: @escaping @Sendable () async -> String?,
        models: [AIModelInfo] = ImagenProvider.defaultModels,
        baseURL: String = "https://generativelanguage.googleapis.com/v1beta"
    ) {
        self.apiKey = apiKey
        self.models = models
        self.baseURL = baseURL
    }

    public func generateImage(
        _ request: AIGenerateImageRequest,
        client: any NetworkClient
    ) async throws -> [AIGeneratedImage] {
        guard let prompt = request.prompt, !prompt.isEmpty else {
            throw AIError.generationFailed("Imagen requires a prompt")
        }
        guard let key = await apiKey(), !key.isEmpty else {
            throw AIError.generationFailed("no Google AI API key — set one to use Imagen")
        }
        return try await predict(
            prompt: prompt,
            modelID: resolveModel(request.model),
            aspectRatio: aspectRatio(width: request.width, height: request.height),
            seed: request.seed,
            count: request.count,
            key: key,
            baseURL: baseURL,
            outputDirectory: request.outputDirectory,
            client: client
        )
    }

    /// The shared `:predict` choreography, parameterized on everything both entry
    /// surfaces vary — the `ai.generateImage` path (key/base injected at
    /// construction) and the runtime `ai.run` workflow path (key/base from the
    /// per-call connection). Applies Imagen's seed policy: an explicit seed forces
    /// `sampleCount = 1` + `addWatermark: false`; without one, no seed is sent (the
    /// result is non-deterministic and its echoed seed is nil).
    private func predict(
        prompt: String,
        modelID: String,
        aspectRatio: String?,
        seed: Int?,
        count: Int?,
        key: String,
        baseURL: String,
        outputDirectory: String?,
        client: any NetworkClient
    ) async throws -> [AIGeneratedImage] {
        let hasSeed = seed != nil
        let sampleCount = hasSeed ? 1 : min(max(count ?? 1, 1), 4)
        let parameters = Parameters(
            sampleCount: sampleCount,
            aspectRatio: aspectRatio,
            seed: seed,
            addWatermark: hasSeed ? false : nil
        )
        let body = try JSONEncoder().encode(Body(instances: [Instance(prompt: prompt)], parameters: parameters))

        guard let url = URL(string: "\(baseURL)/models/\(modelID):predict") else {
            throw AIError.generationFailed("invalid Imagen endpoint for model \(modelID)")
        }
        let response = try await client.send(NetRequest(
            method: "POST",
            url: url,
            headers: ["x-goog-api-key": key, "Content-Type": "application/json"],
            body: body,
            timeout: 120
        ))

        let decoded = try? JSONDecoder().decode(PredictResponse.self, from: response.body)
        guard response.isSuccess else {
            let message = decoded?.error?.message ?? String(decoding: response.body.prefix(300), as: UTF8.self)
            throw AIError.generationFailed("Imagen HTTP \(response.status): \(message)")
        }
        guard let predictions = decoded?.predictions, !predictions.isEmpty else {
            throw AIError.generationFailed("Imagen returned no images")
        }

        return try predictions.enumerated().compactMap { index, prediction in
            guard let base64 = prediction.bytesBase64Encoded, let bytes = Data(base64Encoded: base64) else {
                return nil
            }
            return try RemoteImageOutput.make(
                bytes: bytes,
                mimeType: prediction.mimeType ?? "image/png",
                seed: seed,
                outputDirectory: outputDirectory,
                index: index
            )
        }
    }

    // MARK: - Helpers

    private func resolveModel(_ requested: String?) -> String {
        if let requested, models.contains(where: { $0.id == requested }) { return requested }
        return models.first?.id ?? "imagen-4.0-generate-001"
    }

    /// Map a requested pixel size to the nearest Imagen-supported aspect ratio;
    /// `nil` when no dimensions were given (Imagen defaults to 1:1).
    private func aspectRatio(width: Int?, height: Int?) -> String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        let target = Double(width) / Double(height)
        let ratios: [(String, Double)] = [
            ("1:1", 1), ("3:4", 3.0 / 4), ("4:3", 4.0 / 3), ("9:16", 9.0 / 16), ("16:9", 16.0 / 9)
        ]
        return ratios.min { abs($0.1 - target) < abs($1.1 - target) }?.0
    }

    private static func model(id: String, label: String) -> AIModelInfo {
        AIModelInfo(
            id: id,
            label: label,
            capabilities: [.imageGeneration],
            availability: .ready,
            offlineCapable: false,
            license: "Google Gemini API Terms"
        )
    }

    // MARK: - Wire types

    private struct Body: Encodable {
        let instances: [Instance]
        let parameters: Parameters
    }

    private struct Instance: Encodable {
        let prompt: String
    }

    private struct Parameters: Encodable {
        let sampleCount: Int
        let aspectRatio: String?
        let seed: Int?
        let addWatermark: Bool?
    }

    private struct PredictResponse: Decodable {
        let predictions: [Prediction]?
        let error: APIError?
    }

    private struct Prediction: Decodable {
        let bytesBase64Encoded: String?
        let mimeType: String?
    }

    private struct APIError: Decodable {
        let code: Int?
        let message: String?
    }
}

// MARK: - Runtime workflow surface (ai.run / ai.describeInputs)

/// Imagen as a **fixed-schema** ``AIWorkflowProvider`` — the runtime, JS-reachable
/// counterpart to its `ai.generateImage` role. It answers `ai.describeInputs`
/// with a static control set (no graph, no network probe) and `ai.run` with a
/// one-shot `:predict` (no per-step progress — a coarse `running` then the
/// `image`(s) then `done`), so a JS app renders Imagen controls through the *same*
/// UI it uses for a ComfyUI graph. This is what makes the runtime surface genuinely
/// provider-agnostic rather than ComfyUI-only.
///
/// Auth for this path prefers a key carried on the **connection** (a header
/// resolved from `secretRef` server-side — the fully-runtime route) and falls back
/// to the key injected at construction; the endpoint is `connection.baseURL` when
/// it's a real `http(s)` origin, else the injected `baseURL`. So an app can drive
/// Imagen either by supplying everything in the call or by relying on what it wired
/// in — no connection is required (the plugin passes a placeholder).
extension ImagenProvider: AIWorkflowProvider {
    public var providerID: String {
        "imagen"
    }

    /// Imagen's supported aspect ratios (the `aspectRatio` enum's options).
    static let aspectRatios = ["1:1", "3:4", "4:3", "9:16", "16:9"]

    public func describeInputs(
        config _: AIWorkflowConfig,
        client _: any NetworkClient
    ) async throws -> AIInputSchema {
        var fields: [AIInputField] = [
            AIInputField(key: "prompt", label: "Prompt", type: .text)
        ]
        // Advertise the model choice only when there's more than one.
        if models.count > 1 {
            fields.append(AIInputField(
                key: "model", label: "Model", type: .enum,
                value: .string(models.first?.id ?? ""), options: models.map(\.id)
            ))
        }
        fields.append(contentsOf: [
            AIInputField(
                key: "aspectRatio", label: "Aspect ratio", type: .enum,
                value: .string("1:1"), options: Self.aspectRatios
            ),
            AIInputField(
                key: "count", label: "Number of images", type: .int,
                value: .number(1), min: 1, max: 4, step: 1
            ),
            AIInputField(key: "seed", label: "Seed", type: .seed)
        ])
        // Fixed schema, always live (no /object_info to cross), so never degraded.
        return AIInputSchema(inputs: fields, degraded: false)
    }

    public func runWorkflow(
        config: AIWorkflowConfig,
        client: any NetworkClient
    ) -> AsyncThrowingStream<AIRunEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let inputs = config.inputs
                    guard let prompt = Self.string(inputs["prompt"]), !prompt.isEmpty else {
                        throw AIError.generationFailed("Imagen requires a prompt")
                    }
                    let key = try await resolvedKey(config.connection)
                    let base = Self.endpointBaseURL(config.connection) ?? baseURL
                    let modelID = resolveModel(Self.string(inputs["model"]))

                    // Coarse `running` — Imagen is one-shot (no progressive tier).
                    continuation.yield(.progress(stage: "running"))
                    let images = try await predict(
                        prompt: prompt,
                        modelID: modelID,
                        aspectRatio: Self.string(inputs["aspectRatio"]),
                        seed: Self.int(inputs["seed"]),
                        count: Self.int(inputs["count"]),
                        key: key,
                        baseURL: base,
                        outputDirectory: config.outputDirectory,
                        client: client
                    )
                    for image in images {
                        try Task.checkCancellation()
                        continuation.yield(.image(image))
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Prefer a key carried on the connection (a `secretRef`-resolved header),
    /// falling back to the injected closure. A left-behind `${secret}` placeholder
    /// (no store to resolve it) is treated as absent.
    private func resolvedKey(_ connection: AIConnection) async throws -> String {
        if let header = connection.headers["x-goog-api-key"],
           !header.isEmpty, !header.contains("${secret}")
        {
            return header
        }
        if let key = await apiKey(), !key.isEmpty { return key }
        throw AIError.generationFailed("no Google AI API key — set one to use Imagen")
    }

    /// The connection's `baseURL` when it's a real `http(s)` origin; `nil` for the
    /// plugin's `about:blank` placeholder (so the injected base is used instead).
    private static func endpointBaseURL(_ connection: AIConnection) -> String? {
        guard let scheme = connection.baseURL.scheme, scheme == "http" || scheme == "https" else { return nil }
        return connection.baseURL.absoluteString
    }

    private static func string(_ value: JSONValue?) -> String? {
        if case let .string(string)? = value { return string }
        return nil
    }

    private static func int(_ value: JSONValue?) -> Int? {
        switch value {
        case let .number(number)?: Int(number)
        case let .string(string)?: Int(string)
        default: nil
        }
    }
}
