import Foundation
import SwiftPWACore
@testable import SwiftPWAQwenTTS
import Testing

// swiftformat:disable:next wrap wrapArguments
#if canImport(ONNXRuntime) || canImport(ONNXRuntimeAndroid) || canImport(ONNXRuntimeDesktop) || canImport(ONNXRuntimeDirectML)

    /// A capability read must not queue behind a synthesis.
    ///
    /// `QwenTTSBackend` is an `actor` and `AIPlugin` serves `ai.info` as `await
    /// backend.info()`, so while the autoregressive loop is running inside the
    /// actor nothing else can enter it. Reported by an adopter: `ai.info` took
    /// **1–25 ms** idle and **10,886 ms** when called four seconds into an
    /// `ai.generateAudio`, returning the moment generation finished. Their
    /// user-visible symptom was a voice picker that stayed blank for ten seconds
    /// — opened, of course, while something was playing.
    ///
    /// Needs `QWEN_TTS_MODEL_DIR` (real weights): the whole point is a synthesis
    /// long enough to overlap, which a mock can't produce faithfully.
    struct QwenTTSConcurrencyTests {
        @Test func infoAnswersWhileSynthesisIsRunning() async throws {
            guard let dir = ProcessInfo.processInfo.environment["QWEN_TTS_MODEL_DIR"] else { return }
            let backend = QwenTTSBackend(modelDirectory: URL(fileURLWithPath: dir))

            // Baseline: what a capability read costs with the actor idle.
            let idle = try await millis { _ = await backend.info() }

            // Start a synthesis and let it get well underway, then read.
            async let synthesis = backend.generateAudio(AIGenerateAudioRequest(
                prompt: "The quick brown fox jumps over the lazy dog, and then says hello.",
                voice: "ryan",
                outputDirectory: FileManager.default.temporaryDirectory.path
            ))
            try await Task.sleep(for: .seconds(4))

            let busy = try await millis { _ = await backend.info() }
            let result = try await synthesis
            let audioMs = result.audio.durationMs ?? 0

            print("[qwen-tts-concurrency] info() idle \(Int(idle)) ms, during synthesis \(Int(busy)) ms")

            // The bug's signature is `info()` returning only when generation
            // does. Generation takes many seconds; a capability read that only
            // stats a few files has no business being anywhere near that, so a
            // generous ceiling still separates "answered" from "queued".
            #expect(
                busy < 1000,
                "ai.info queued behind generateAudio: \(Int(busy)) ms vs \(Int(idle)) ms idle, \(audioMs) ms of audio"
            )
        }

        private func millis(_ body: () async -> Void) async throws -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            await body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
    }
#endif
