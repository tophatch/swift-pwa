import Foundation
import SwiftPWACore
import SwiftPWAONNX
@testable import SwiftPWAStableDiffusion
import Testing

// swiftformat:disable:next wrap wrapArguments
#if canImport(ONNXRuntime) || canImport(ONNXRuntimeAndroid) || canImport(ONNXRuntimeDesktop) || canImport(ONNXRuntimeDirectML)

    /// That `ai.info().provider` reports the execution provider a real Stable
    /// Diffusion session loaded on. Separate from
    /// `StableDiffusionReferenceVerificationTests` because this needs only the
    /// weights, not the PyTorch reference tensors that test compares against.
    ///
    /// Set `SD_MODEL_DIR` to a directory holding a flat export —
    /// `text_encoder.onnx` / `unet.onnx` / `vae_decoder.onnx` / `vocab.json` /
    /// `merges.txt` — i.e. the layout `StableDiffusionModelSource` downloads
    /// into. Defaults to the LCM fp16 spec; override with `SD_MODEL_SPEC=sdturbo`.
    struct StableDiffusionProviderTests {
        @Test func reportsExecutionProviderAfterGenerating() async throws {
            guard let dir = ProcessInfo.processInfo.environment["SD_MODEL_DIR"] else { return }
            let base = URL(fileURLWithPath: dir)
            let spec: StableDiffusionModelSpec = ProcessInfo.processInfo
                .environment["SD_MODEL_SPEC"] == "sdturbo" ? .sdTurboFp16 : .lcmDreamshaperFp16

            let backend = StableDiffusionBackend(
                textEncoderPath: base.appendingPathComponent("text_encoder.onnx").path,
                unetPath: base.appendingPathComponent("unet.onnx").path,
                vaeDecoderPath: base.appendingPathComponent("vae_decoder.onnx").path,
                tokenizerVocabPath: base.appendingPathComponent("vocab.json").path,
                tokenizerMergesPath: base.appendingPathComponent("merges.txt").path,
                spec: spec
            )

            // Unknown until a session exists — the EP is chosen at CreateSession.
            let before = await backend.info()
            #expect(before.available)
            #expect(before.imageGeneration)
            #expect(before.provider == nil)

            // One step is enough to force the sessions to load; this test is
            // about the provider, not image quality.
            let result = try await backend.generateImage(AIGenerateImageRequest(
                prompt: "a red apple on a table",
                steps: 1,
                outputDirectory: FileManager.default.temporaryDirectory.path
            ))
            #expect(!result.images.isEmpty)

            // A CPU-EP build; anything else here would mean a GPU tier engaged
            // without being asked, which is what `provider` exists to reveal.
            let after = await backend.info()
            #expect(after.provider == "cpu")
            print("[sd-provider] provider after generating: \(after.provider ?? "nil")")

            // unload() drops the sessions, so the provider is unknown again
            // rather than stale.
            await backend.unload()
            #expect(await backend.info().provider == nil)
        }
    }
#endif
