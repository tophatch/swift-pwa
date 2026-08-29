# On-device AI performance

Notes on what actually makes the ONNX Runtime tier fast, measured rather than
assumed. Right now this covers the **Apple** side of `SwiftPWAQwenTTS`
(`ai.generateAudio`), because that's where the question came up; the reasoning
generalizes to the other ONNX backends and the caveats are called out where it
doesn't.

## The short version

- The single biggest lever on Apple/desktop is the **graph-optimization level**,
  not the execution provider. Raising it from `.basic` to `.all` cut Qwen3-TTS
  synthesis by ~1.5x with **bit-identical audio**.
- **CoreML is not a win here, and mostly doesn't even load.** Three of four
  configurations fail at session creation and fall back to CPU; the one that
  loads is *slower* than the CPU EP and changes the output.
- Speech synthesis on the CPU EP is still **slower than real time** on an
  M-series laptop (RTF ~2.5). Plan for generate-then-play, not streaming
  playback.

## Measuring it yourself

The benchmark lives in the normal test suite, not in a scratch harness:

```bash
SWIFT_PWA_ONNXRUNTIME=1 \
QWEN_TTS_MODEL_DIR=/path/to/qwen-tts-model \
QWEN_TTS_BENCH=1 \
swift test -c release -Xswiftc -enable-testing \
  --filter QwenTTSBenchmarkTests
```

Three tests, each opt-in via environment variable:

| test | needs | what it does |
| --- | --- | --- |
| `graphOptimizationPreservesAudio` | `QWEN_TTS_MODEL_DIR` | correctness: `.basic` vs `.all` waveform correlation |
| `benchmarksSessionConfigurations` | `+ QWEN_TTS_BENCH=1` | the timing matrix below |
| `reportsCoreMLExecutionProviderOutcome` | `+ QWEN_TTS_BENCH=1` | which CoreML configurations load at all |

**Build release.** Debug is not a slow version of release here, it's a different
order of magnitude — the tokenizer, sampler and the autoregressive loop are
Swift, and an adopter measured **219 s debug against 29 s release** for the same
utterance. Any number from a debug build is noise.

**Interleave repeats.** `benchmarksSessionConfigurations` runs configurations
round-robin for `QWEN_TTS_BENCH_ROUNDS` (default 3) rounds and reports the best
sample per configuration. This is not ceremony: a straight-through run on a
laptop measured everything ~1.5x slow once the machine had heated up under
sustained ORT load, which would have been read as a property of whichever
configuration happened to run last.

## Graph optimization: `.basic` → `.all`

`QwenTTSBackend` used to pin every platform to `ORT_ENABLE_BASIC`. That was
inherited from a real Android constraint and never revisited:

> The extended fusions rewrite standard ops into fused `com.microsoft.*` contrib
> ops. The **Android** ONNX Runtime package has no **float16** kernels for those,
> and this pipeline's talker is fp16 — a fused fp16 Gelu has no kernel and the
> session fails outright. (Same root cause as the Stable-Diffusion Gelu-fusion
> gotcha.)

Apple and desktop packages *do* carry the fp16 contrib kernels, and those
transformer fusions are precisely what this pipeline is made of. Holding every
platform to Android's ceiling was leaving that on the floor. The level is now
platform-derived — `.basic` on Android, `.all` everywhere else — overridable via
`QwenTTSBackend(graphOptimization:)`.

Measured on an M-series MacBook (10 cores, 32 GB), 65-character prompt, release
build, best of 3 interleaved rounds:

| configuration | provider | cold | warm | audio | RTF |
| --- | --- | --- | --- | --- | --- |
| `.basic` (through v0.10.1) | cpu | 21.1 s | 21.6 s | 5.8 s | **3.70** |
| `.all` | cpu | 15.8 s | 14.7 s | 5.8 s | **2.52** |
| CoreML, static shapes only, `.all` | coreml | 21.1 s | 17.7 s | 6.3 s | 2.80 |

RTF is wall time ÷ audio duration; lower is better, below 1.0 is faster than
real time. The `.all` speedup measured between **1.5x and 1.9x** across runs
depending on how busy the machine was — 1.47x is the conservative figure from
the controlled run above.

**The output is unchanged.** Fusions are numerically approximate and this
pipeline samples with a *seeded* RNG, so a small logit shift could fork the token
stream into different-but-plausible speech. It doesn't:
`graphOptimizationPreservesAudio` decodes both WAVs and compares them —
**140,160 samples, correlation 0.999999999822609**, identical length.

## CoreML: measured, and not viable for this pipeline

The vendored Apple ONNX Runtime has always contained the CoreML EP
(`_OrtSessionOptionsAppendExecutionProvider_CoreML` is in the binary and
`coreml_provider_factory.h` is in the module map) — swift-pwa simply never
appended it, so every ONNX session on Apple ran on the CPU EP. It can now be
requested per session via `OrtCoreMLOptions`, and `QwenTTSBackend` takes a
`coreML:` parameter. **It defaults to off, because it loses.**

What the measurement showed, on the talker graph (2629 nodes):

- **CoreML claims most of the graph and then shatters it.** `GetCapability`
  reports 2119 of 2629 nodes "supported by CoreML" — spread across **170
  partitions**. Each partition boundary is a CoreML↔CPU handoff, and this
  pipeline runs the talker plus 15 code-predictor calls *per audio frame*
  (~750 session runs for six seconds of speech). Handoff cost dominates before
  any arithmetic happens.
Running `reportsCoreMLExecutionProviderOutcome` gives, verbatim:

| configuration | outcome |
| --- | --- |
| `all (cpu+gpu+ane)`, MLProgram | refused at session creation → ran on cpu |
| `cpu+ane`, MLProgram | refused at session creation → ran on cpu |
| `cpu+gpu`, MLProgram | refused at session creation → ran on cpu |
| `all`, NeuralNetwork | **loaded on coreml, then failed at Run** |
| `all`, static shapes only | ran on coreml (and lost on speed) |

- **The three MLProgram configurations fail at session creation** with `Failed to
  build the model execution plan … error code: -14`, preceded by a wall of
  `E5RT` validation errors: `Invalid tensor rank 0 inferred from: ios18.squeeze`,
  `has unbounded dimension which is not supported`, `shapes of x and y are not
  broadcastable`. These are the decoder's dynamic KV-cache shapes meeting
  CoreML's requirement for bounded ones.
- **The NeuralNetwork format loads and then dies on the first token** — the most
  interesting failure, because it names the structural blocker outright:

  > Input (`/Concat_output_0`) has a dynamic shape (`{-1,8,-1,128}`) but the
  > runtime shape (`{1,8,0,128}`) has zero elements. This is not supported by the
  > CoreML EP.

  That zero-element tensor is the **empty KV cache on the first decode step**.
  Every autoregressive generation begins with one (`OrtModelSession` even keeps a
  1-byte scratch pointer so ORT has something non-null to hold), so this isn't an
  edge case to route around — it's step 0 of every single utterance.
- **The one configuration that survives is slower and changes the output.**
  `requireStaticInputShapes: true` makes CoreML decline the dynamic nodes
  (partitions drop to 112 of 2629, only 804 nodes taken), which loads and runs —
  and lands at RTF 2.80 against the CPU EP's 2.52. It also produced 6.3 s of
  audio where every CPU configuration produced 5.8 s: the numerics differ enough
  to fork the seeded token stream.

The transferable shape of this: **CoreML pays off for one big static-shape graph
invoked a few times, and loses for a small dynamic graph invoked hundreds of
times.** An autoregressive decoder is the second thing. A vision encoder — the
MobileSAM image encoder, say, one fixed 1024×1024 pass per image — is the first,
and is the obvious next candidate to measure. It has not been measured yet, so
`MobileSAMBackend` is untouched.

### A trap worth knowing

`coreml_provider_factory.h` documents the `MLComputeUnits` values as
`MLComputeUnitsAll` / `MLComputeUnitsCPUAndGPU` / `MLComputeUnitsCPUAndNeuralEngine`
/ `MLComputeUnitsCPUOnly`. **The implementation accepts none of those spellings.**
ORT 1.27 takes the bare names `CPUAndGPU` / `CPUAndNeuralEngine` / `CPUOnly`, and
"all" is not settable at all — it's the default you get by omitting the key.

Passing a documented-but-wrong value throws at session creation, which the
fallback path turns into a silent CPU run. The first version of this benchmark
did exactly that and produced a tidy table showing CoreML performing *identically
to CPU* — because it was CPU. `OrtCoreMLOptions.ComputeUnits` now models only the
values that work, `QwenTTSBackend.activeProvider` reports what a session actually
loaded on, and the benchmark asserts against it rather than against intent.

## Where the remaining time goes

`.all` on the CPU EP is the best configuration available today, and it is still
slower than real time. The cost is structural rather than a missing flag.
Profiling (ONNX Runtime's per-operator profiler, full synthesis) says where:

| stage | share of wall | calls | in kernels | top op |
| --- | --- | --- | --- | --- |
| code-predictor | 55.1% | 1,095 | 92.5% | `MatMul` 55.0% |
| talker (AR + prefill) | 31.6% | 96 | 89.9% | `MatMul` 59.9% |
| vocoder | 9.7% | 1 | 99.9% | `Conv` 75.9% |
| Swift (tokenizer, sampler, embeddings) | 3.6% | — | — | — |

**Levers that have been measured and ruled out** — recorded so they are not
re-derived:

| lever | result |
| --- | --- |
| Fuse the 15 code-predictor calls per frame | **≤4% of wall.** Only 7.5% of a `Run` is outside kernels, so removing `Run` boundaries recovers almost nothing — and the 15 steps have `QwenSampler.sampleCP` between them, so fusing means moving top-k, temperature and the seeded RNG into the graph. |
| ORT IO binding / reused input buffers | **≤4%.** Targets the same `Run` boundary. |
| fp16 the code-predictor | **0.52× — 2× slower.** ORT's CPU provider has no native fp16 kernels for these ops and emulates them via fp32, so halving weight bytes buys nothing while every op pays a conversion. It also forked the seeded token stream (140,160 vs 147,840 samples). |

> **Trap:** ONNX Runtime **1.27** (the version vendored here) cannot load an
> fp16 code-predictor at `ORT_ENABLE_ALL` at all — `SimplifiedLayerNormFusion`
> fails naming an `InsertedPrecisionFreeCast_…` node the graph does not
> contain. Fixed in **1.29**. Bump the runtime before revisiting fp16 anywhere
> in this tier.

Single-token decode is `MatMul`-bound and the CPU provider computes those in
fp32. **Moving them to the GPU or ANE is the only remaining lever that changes
the arithmetic** — which is a native CoreML or MLX backend, scoped in
[`docs/proposals/apple-native-tts-inference.md`](proposals/apple-native-tts-inference.md).

Until that lands, treat on-device TTS as generate-then-play: synthesize to a
WAV, then play it. See [`docs/ai-plugin.md`](ai-plugin.md) for the
`ai.generateAudio` contract and the memory notes (~3 GB peak, `lowMemory:`).
