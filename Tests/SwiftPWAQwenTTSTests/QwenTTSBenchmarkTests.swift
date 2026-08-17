import Foundation
import SwiftPWACore
import SwiftPWAONNX
@testable import SwiftPWAQwenTTS
import Testing

// Same gate as the E2E suite — it drives the real ONNX backend.
// swiftformat:disable:next wrap wrapArguments
#if canImport(ONNXRuntime) || canImport(ONNXRuntimeAndroid) || canImport(ONNXRuntimeDesktop) || canImport(ONNXRuntimeDirectML)

    /// Opt-in synthesis **benchmark** across session configurations — the
    /// measurement behind the graph-optimization and CoreML choices in
    /// `QwenTTSBackend`. Needs `QWEN_TTS_MODEL_DIR` (as the E2E suite does) plus
    /// `QWEN_TTS_BENCH=1`, because each configuration loads ~2.4 GB of weights
    /// and synthesizes for real; the whole matrix takes minutes.
    ///
    /// Reports, per configuration, cold (first call, includes session create +
    /// any CoreML compile) and warm (second call, sessions resident) wall time,
    /// plus the **real-time factor** — wall ÷ audio duration, which is the
    /// number that decides whether this is usable for playback. Lower is better;
    /// < 1.0 is faster than real time.
    struct QwenTTSBenchmarkTests {
        private struct Config {
            let name: String
            let graph: OrtGraphOptimizationLevel?
            let coreML: OrtCoreMLOptions?
        }

        private struct Timing {
            var coldMs: Double
            var warmMs: Double
            var audioMs: Double
            var frames: Int
            var provider: String
        }

        /// Long enough to be dominated by the autoregressive loop rather than by
        /// setup, short enough to run the matrix in a sitting.
        private static let prompt = "The quick brown fox jumps over the lazy dog, and then says hello."

        @Test func benchmarksSessionConfigurations() async throws {
            guard let dir = ProcessInfo.processInfo.environment["QWEN_TTS_MODEL_DIR"],
                  ProcessInfo.processInfo.environment["QWEN_TTS_BENCH"] == "1" else { return }
            let modelDir = URL(fileURLWithPath: dir)
            let cache = FileManager.default.temporaryDirectory
                .appendingPathComponent("qwen-tts-coreml-cache", isDirectory: true)

            var configs: [Config] = [
                Config(name: "cpu graph=.basic (v0.10.1 shipped)", graph: .basic, coreML: nil),
                Config(name: "cpu graph=.all", graph: .all, coreML: nil)
            ]
            #if os(macOS) || os(iOS)
                // The only CoreML configuration that actually loads — see
                // `reportsCoreMLExecutionProviderOutcome` for the three that
                // don't. Kept in the timed matrix because "it loads and is still
                // slower" is the load-bearing half of the finding.
                configs.append(Config(
                    name: "coreml static-shapes-only + graph=.all",
                    graph: .all,
                    coreML: OrtCoreMLOptions(
                        computeUnits: .all, requireStaticInputShapes: true, modelCacheDirectory: cache.path
                    )
                ))
            #endif

            // Interleave repeats rather than running each configuration to
            // completion in turn: a laptop under sustained ORT load drifts (an
            // earlier straight-through run measured everything ~1.5x slow after
            // the machine heated up), and round-robin spreads that drift across
            // all configurations instead of penalising whichever ran last. Report
            // the *minimum* per configuration — the least-disturbed sample.
            let rounds = Int(ProcessInfo.processInfo.environment["QWEN_TTS_BENCH_ROUNDS"] ?? "3") ?? 3
            var samples: [String: [Timing]] = [:]
            for round in 1 ... rounds {
                for config in configs {
                    let backend = QwenTTSBackend(
                        modelDirectory: modelDir, graphOptimization: config.graph, coreML: config.coreML
                    )
                    let cold = try await time(backend)
                    let warm = try await time(backend)
                    let provider = await backend.activeProvider
                    if config.coreML == nil {
                        // A CPU configuration reporting anything else means the
                        // knobs aren't wired the way this table claims.
                        #expect(provider == "cpu", "\(config.name) ran on \(provider ?? "nil")")
                    }
                    samples[config.name, default: []].append(Timing(
                        coldMs: cold.wallMs, warmMs: warm.wallMs, audioMs: warm.audioMs,
                        frames: warm.frames, provider: provider ?? "nil"
                    ))
                    await backend.unload()
                }
                print("[qwen-tts-bench] round \(round)/\(rounds) done")
            }

            func pad(_ s: String, _ n: Int) -> String {
                s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
            }
            func secs(_ ms: Double) -> String {
                pad(String(format: "%.1f", ms / 1000), 9)
            }
            print("\n[qwen-tts-bench] \(Self.prompt.count) chars, \(hostDescription()), best of \(rounds)")
            print(
                pad("configuration", 42) + pad("provider", 9) + pad("cold s", 9)
                    + pad("warm s", 9) + pad("audio s", 9) + "RTF"
            )
            for config in configs {
                guard let runs = samples[config.name], let best = runs.min(by: { $0.warmMs < $1.warmMs })
                else { continue }
                print(
                    pad(config.name, 42) + pad(best.provider, 9)
                        + secs(runs.map(\.coldMs).min() ?? 0) + secs(best.warmMs) + secs(best.audioMs)
                        + String(format: "%.2f", best.warmMs / best.audioMs)
                )
            }

            // The benchmark is a measurement, but it should still fail if a
            // configuration stops producing audio at all.
            #expect(samples.values.allSatisfy { $0.allSatisfy { $0.audioMs > 500 } })
            #expect(samples.count == configs.count)
        }

        /// What the CoreML execution provider actually does with this pipeline,
        /// recorded rather than asserted — the measurement behind `QwenTTSBackend`
        /// shipping on the CPU EP. Reports, per graph, how CoreML partitions it
        /// and whether the session survives creation.
        ///
        /// This is a *finding*, not a regression guard: if a future ONNX Runtime
        /// or OS makes these graphs load, the printed output changes and the
        /// documented conclusion should be revisited.
        @Test func reportsCoreMLExecutionProviderOutcome() async throws {
            #if os(macOS) || os(iOS)
                guard let dir = ProcessInfo.processInfo.environment["QWEN_TTS_MODEL_DIR"],
                      ProcessInfo.processInfo.environment["QWEN_TTS_BENCH"] == "1" else { return }
                let modelDir = URL(fileURLWithPath: dir)
                let cache = FileManager.default.temporaryDirectory
                    .appendingPathComponent("qwen-tts-coreml-probe", isDirectory: true)

                let variants: [(String, OrtCoreMLOptions)] = [
                    ("all (cpu+gpu+ane)", OrtCoreMLOptions(computeUnits: .all, modelCacheDirectory: cache.path)),
                    (
                        "cpu+ane",
                        OrtCoreMLOptions(computeUnits: .cpuAndNeuralEngine, modelCacheDirectory: cache.path)
                    ),
                    ("cpu+gpu", OrtCoreMLOptions(computeUnits: .cpuAndGPU, modelCacheDirectory: cache.path)),
                    (
                        "neural-network format",
                        OrtCoreMLOptions(
                            computeUnits: .all, modelFormat: .neuralNetwork, modelCacheDirectory: cache.path
                        )
                    ),
                    (
                        "static-shapes-only",
                        OrtCoreMLOptions(
                            computeUnits: .all, requireStaticInputShapes: true, modelCacheDirectory: cache.path
                        )
                    )
                ]

                var outcomes: [(String, String)] = []
                for (name, options) in variants {
                    let backend = QwenTTSBackend(modelDirectory: modelDir, graphOptimization: .all, coreML: options)
                    // A configuration can fail in three distinct places, and
                    // which one matters: refused at session creation (falls back
                    // to CPU), accepted and then failed at Run, or it worked.
                    var outcome: String
                    do {
                        _ = try await backend.generateAudio(
                            AIGenerateAudioRequest(
                                prompt: "Short probe.", voice: "ryan",
                                outputDirectory: FileManager.default.temporaryDirectory.path
                            )
                        )
                        outcome = await "ran on \(backend.activeProvider ?? "nil")"
                    } catch {
                        outcome = await "loaded on \(backend.activeProvider ?? "nil"), failed at Run: \(error)"
                    }
                    outcomes.append((name, outcome))
                    await backend.unload()
                }

                print("\n[qwen-tts-coreml] execution provider actually used, per configuration:")
                for (name, outcome) in outcomes { print("[qwen-tts-coreml]   \(name): \(outcome)") }
            #endif
        }

        /// The speed win from `.all` is only a win if the audio is unchanged.
        /// Extended fusions are numerically approximate, and this pipeline
        /// samples with a **seeded** RNG — so a small logit shift can fork the
        /// token stream and yield different (not merely noisier) speech. Compare
        /// the decoded waveforms of `.basic` and `.all` directly.
        ///
        /// Gated on `QWEN_TTS_MODEL_DIR` alone (no `QWEN_TTS_BENCH`) — this is a
        /// correctness check, so it should run whenever the weights are present.
        @Test func graphOptimizationPreservesAudio() async throws {
            guard let dir = ProcessInfo.processInfo.environment["QWEN_TTS_MODEL_DIR"] else { return }
            let modelDir = URL(fileURLWithPath: dir)

            func samples(_ level: OrtGraphOptimizationLevel) async throws -> [Float] {
                // Each backend is scope-local, so its ~2.4 GB of sessions are
                // released before the next configuration loads.
                let backend = QwenTTSBackend(modelDirectory: modelDir, graphOptimization: level)
                let result = try await backend.generateAudio(
                    AIGenerateAudioRequest(
                        prompt: Self.prompt, voice: "ryan",
                        outputDirectory: FileManager.default.temporaryDirectory.path
                    )
                )
                let path = try #require(result.audio.path)
                return try Self.decodeWAV(Data(contentsOf: URL(fileURLWithPath: path)))
            }

            let basic = try await samples(.basic)
            let all = try await samples(.all)

            #expect(!basic.isEmpty)
            // A forked token stream shows up as a different length long before
            // it shows up as a correlation dip.
            #expect(basic.count == all.count, "sample counts differ: \(basic.count) vs \(all.count)")

            let n = min(basic.count, all.count)
            var dot = 0.0, na = 0.0, nb = 0.0
            for i in 0 ..< n {
                dot += Double(basic[i]) * Double(all[i])
                na += Double(basic[i]) * Double(basic[i])
                nb += Double(all[i]) * Double(all[i])
            }
            let correlation = dot / (na.squareRoot() * nb.squareRoot())
            print("[qwen-tts-graphopt] \(n) samples, correlation \(correlation)")
            #expect(correlation > 0.9999, "graph=.all changed the audio (correlation \(correlation))")
        }

        /// Minimal 16-bit PCM WAV reader — enough for what `QwenWAV` writes.
        private static func decodeWAV(_ data: Data) throws -> [Float] {
            try #require(data.count > 44)
            let pcm = data.dropFirst(44)
            return stride(from: 0, to: pcm.count - 1, by: 2).map { offset in
                let lo = UInt16(pcm[pcm.startIndex + offset])
                let hi = UInt16(pcm[pcm.startIndex + offset + 1])
                return Float(Int16(bitPattern: lo | (hi << 8))) / 32768
            }
        }

        private func time(_ backend: QwenTTSBackend) async throws -> (wallMs: Double, audioMs: Double, frames: Int) {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = try await backend.generateAudio(
                AIGenerateAudioRequest(
                    prompt: Self.prompt, voice: "ryan",
                    outputDirectory: FileManager.default.temporaryDirectory.path
                )
            )
            let wallMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let audioMs = Double(result.audio.durationMs ?? 0)
            return (wallMs, audioMs, 0)
        }

        private func hostDescription() -> String {
            let info = ProcessInfo.processInfo
            return "\(info.processorCount) cores, \(info.physicalMemory / 1_073_741_824) GB"
        }
    }
#endif
