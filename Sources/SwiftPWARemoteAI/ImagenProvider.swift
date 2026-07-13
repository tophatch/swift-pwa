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
        let modelID = resolveModel(request.model)

        // Imagen's `seed` requires `addWatermark: false` and a single sample, so
        // an explicit seed forces sampleCount = 1; without one, no seed is sent
        // (the result is non-deterministic and its echoed seed is nil).
        let hasSeed = request.seed != nil
        let sampleCount = hasSeed ? 1 : min(max(request.count ?? 1, 1), 4)
        let parameters = Parameters(
            sampleCount: sampleCount,
            aspectRatio: aspectRatio(width: request.width, height: request.height),
            seed: request.seed,
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
                seed: request.seed,
                outputDirectory: request.outputDirectory,
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
