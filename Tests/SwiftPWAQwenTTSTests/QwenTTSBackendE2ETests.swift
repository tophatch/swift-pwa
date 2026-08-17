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
            // The provider is only decided at CreateSession, so it is unknown
            // until something has actually run.
            #expect(caps.provider == nil)

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

            // …and known once it has. Default build asks for no accelerator, so
            // this is the CPU EP; a "coreml" here would mean the default changed.
            let after = await backend.info()
            #expect(after.provider == "cpu")
            print("[qwen-tts-e2e] wrote \(path) — \(wav.count) bytes, \(ms) ms, provider \(after.provider ?? "nil")")
        }

        /// Opt-in end-to-end of the **download tier**: set `QWEN_TTS_SERVE_URL`
        /// to a base URL serving the release assets by their flat names (e.g. a
        /// local `python -m http.server` over the vendored files). Rewrites the
        /// pinned `customVoice0_6B` source's URLs to that base — so this also
        /// cross-checks the committed checksums against the served bytes — runs
        /// `ai.ensureModel` into a fresh cache (verifying the subdir layout), and
        /// synthesizes from the downloaded files.
        @Test func downloadsAndSynthesizesWhenServed() async throws {
            guard let base = ProcessInfo.processInfo.environment["QWEN_TTS_SERVE_URL"],
                  let baseURL = URL(string: base) else { return }
            let cache = FileManager.default.temporaryDirectory
                .appendingPathComponent("qwen-tts-dl-\(baseURL.port ?? 0)", isDirectory: true)
            try? FileManager.default.removeItem(at: cache)

            let source = QwenTTSModelSource(files: QwenTTSModelSource.customVoice0_6B.files.map { f in
                QwenTTSModelSource.File(
                    url: baseURL.appendingPathComponent(f.url.lastPathComponent),
                    sha256: f.sha256, fileName: f.fileName, sizeBytes: f.sizeBytes
                )
            })
            let backend = QwenTTSBackend(cacheDirectory: cache, source: source)

            var sawDone = false
            var lastBytes: Int64 = 0
            for try await event in backend.ensureModel(AIEnsureModelRequest()) {
                if event.type == "done" { sawDone = true }
                if let b = event.bytesDone { lastBytes = b }
            }
            #expect(sawDone)
            #expect(lastBytes > 2_000_000_000) // ~2.5 GB fetched + checksum-verified
            // The downloaded layout is what the fixed-path backend reads.
            #expect(FileManager.default.fileExists(
                atPath: cache.appendingPathComponent("embeddings/text_embedding.npy").path
            ))

            let result = try await backend.generateAudio(
                AIGenerateAudioRequest(prompt: "Downloaded model works.", voice: "serena")
            )
            let ms = try #require(result.audio.durationMs)
            #expect(ms > 500)
            #expect(ms < 40000)
            print("[qwen-tts-dl] downloaded \(lastBytes) bytes; synthesized \(ms) ms")
        }
    }
#endif
