import Foundation
import SwiftPWACore
@testable import SwiftPWAQwenTTS
import Testing

// The end-to-end test drives the real ONNX backend, so it only compiles where an
// ONNX Runtime is linked (mirrors the backend's own gate).
// swiftformat:disable:next wrap wrapArguments
#if canImport(ONNXRuntime) || canImport(ONNXRuntimeAndroid) || canImport(ONNXRuntimeDesktop) || canImport(ONNXRuntimeDirectML)

    /// Opt-in end-to-end synthesis against the real Qwen3-TTS ONNX models. Set
    /// `QWEN_TTS_MODEL_DIR` to a directory laid out like the elbruno export (the
    /// three graphs at the root, `embeddings/` + `tokenizer/` subdirs). Verifies
    /// the full Swift pipeline — tokenize → prefill warm-up → talker/cp AR loop →
    /// vocoder → WAV — runs, terminates on `codec_eos`, and produces sane audio;
    /// writes the WAV to `QWEN_TTS_OUT` (default the model dir) for a listen.
    struct QwenTTSBackendE2ETests {
        @Test func synthesizesSpeechWhenModelPresent() async throws {
            guard let dir = ProcessInfo.processInfo.environment["QWEN_TTS_MODEL_DIR"] else { return }
            let backend = QwenTTSBackend(modelDirectory: URL(fileURLWithPath: dir))

            let caps = await backend.info()
            #expect(caps.available)
            #expect(caps.audioGeneration)
            #expect(caps.backend == AIBackendID.qwenTTS)

            let outDir = ProcessInfo.processInfo.environment["QWEN_TTS_OUT"] ?? dir
            let result = try await backend.generateAudio(
                AIGenerateAudioRequest(prompt: "Hello from Swift P W A.", voice: "ryan", outputDirectory: outDir)
            )
            #expect(result.backend == AIBackendID.qwenTTS)
            let path = try #require(result.audio.path)
            let wav = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect(wav.count > 44) // header + samples
            let ms = try #require(result.audio.durationMs)
            // "Hello from Swift P W A." runs ~3-15 s across configs; assert it
            // terminated (not the maxFrames backstop) and isn't empty.
            #expect(ms > 500)
            #expect(ms < 40000)
            print("[qwen-tts-e2e] wrote \(path) — \(wav.count) bytes, \(ms) ms")
        }
    }
#endif
