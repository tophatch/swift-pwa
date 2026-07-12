import Foundation
import SwiftPWACore
@testable import SwiftPWARemoteAI
import Testing

/// Opt-in live tests that hit real services — skipped unless the relevant env
/// var is set, so CI and offline runs don't touch the network:
///
/// - **ComfyUI:** set `SWIFT_PWA_LIVE_COMFY` to the instance origin
///   (e.g. `http://comfyui.local:8188`), optionally `SWIFT_PWA_LIVE_COMFY_CKPT`
///   for the checkpoint filename.
/// - **Imagen:** set `GEMINI_API_KEY`.
///
/// Each writes the generated image into the system temp dir and asserts it's a
/// non-trivial image, exercising the whole `URLSessionNetworkClient` → provider
/// → decode path against the real API.
@Suite("Remote AI — live")
struct LiveRemoteAITests {
    private static let comfyURL = ProcessInfo.processInfo.environment["SWIFT_PWA_LIVE_COMFY"]
    private static let geminiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]

    @Test("ComfyUI: prompt → image", .enabled(if: comfyURL != nil))
    func comfyLive() async throws {
        let comfyURL = try #require(Self.comfyURL)
        let base = try #require(URL(string: comfyURL))
        // Auto-select whatever checkpoint the instance has — exercises the
        // /object_info discovery path, no hard-coded model name needed.
        let backend = RemoteImageBackend(
            provider: ComfyUIProvider(baseURL: base, autoSelectCheckpoint: true),
            client: URLSessionNetworkClient()
        )
        let result = try await backend.generateImage(AIGenerateImageRequest(
            prompt: "a red fox in a snowy forest, highly detailed",
            width: 1024, height: 1024, steps: 8, seed: 12345
        ))
        try assertImage(result, label: "comfy")
    }

    @Test("Imagen: prompt → image", .enabled(if: geminiKey != nil))
    func imagenLive() async throws {
        let key = try #require(Self.geminiKey)
        let backend = RemoteImageBackend(
            provider: ImagenProvider(apiKey: { key }),
            client: URLSessionNetworkClient()
        )
        let result = try await backend.generateImage(AIGenerateImageRequest(
            prompt: "a corgi wearing sunglasses, studio photo",
            width: 1024, height: 1024, count: 1
        ))
        try assertImage(result, label: "imagen")
    }

    private func assertImage(_ result: AIGenerateImageResult, label: String) throws {
        let image = try #require(result.images.first)
        let bytes = try #require(image.dataBase64.flatMap { Data(base64Encoded: $0) })
        #expect(bytes.count > 1000) // a real image, not an error blob
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("remote-\(label).png")
        try bytes.write(to: out)
        print("[\(label)] \(result.backend): \(bytes.count) bytes, mime \(image.mimeType ?? "?") → \(out.path)")
    }
}
