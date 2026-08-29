# Proposal: Apple-native inference for on-device TTS (CoreML / MLX)

**Status:** proposal, not scheduled. Written after v0.10.2 measured the ONNX
Runtime CoreML execution provider and found it unusable for this pipeline
([`docs/on-device-ai-performance.md`](../on-device-ai-performance.md)).

## The problem

`SwiftPWAQwenTTS` synthesizes speech on the ONNX Runtime **CPU** execution
provider on every platform. On an M-series Mac that is roughly **1.8–2.5×
slower than real time** (it varies with machine load — the ratio between
configurations is stable, the absolute number is not). Generation cannot keep
up with playback, so a passage plays in bursts.

An adopter shipping read-aloud reports that the Python/MLX implementation they
replaced ran the same class of model on the GPU at about **2.5× faster than
real time** — roughly **8× quicker** than this path. That number is the reason
this document exists: it says the gap is headroom, not a hardware limit.

v0.10.2 already took the free win (graph optimization `.basic` → `.all`, ~1.5×)
and ruled out the obvious lever: the CoreML **execution provider** is not the
answer. It shatters the talker into 170 partitions, three of five
configurations refuse to load, and the one that runs is slower than CPU. That
finding stands; this proposal is about what to do instead.

## Where the time actually goes

Measured on an M-series Mac (10 cores), release build, warm sessions, for a
65-character prompt producing 5,840 ms of audio in 10,559 ms wall:

| stage | time | share | calls | per call |
| --- | --- | --- | --- | --- |
| talker prefill | 700 ms | 6.5% | 23 | 30 ms |
| talker AR loop | 2,722 ms | 25.1% | 73 | 37 ms |
| **code-predictor** | **5,973 ms** | **55.1%** | **1,095** | 5.5 ms |
| vocoder | 1,055 ms | 9.7% | 1 | 1,055 ms |
| **ONNX Runtime total** | **10,449 ms** | **96.4%** | | |
| Swift (tokenizer, sampler, embedding sums) | 396 ms | 3.6% | | |

Two things fall out of this, and both are load-bearing.

**1. The code-predictor dominates, not the talker.** It runs 15× per audio
frame (one per codebook) against the talker's once. Everyone's intuition —
including mine before measuring — is that the big fp16 talker is the cost. It
isn't; it's second.

**2. It is compute bound, and the compute is `MatMul`.** ONNX Runtime's own
per-operator profiler, over a full synthesis:

| graph | Runs | ms/Run | in kernels | Run-boundary overhead | top op |
| --- | --- | --- | --- | --- | --- |
| code-predictor | 1,035 | 8.06 | **92.5%** | 7.5% | `MatMul` 55.0% |
| talker | 89 | 47.29 | **89.9%** | 10.1% | `MatMul` 59.9% |
| vocoder | 1 | 1,709.71 | **99.9%** | 0.1% | `Conv` 75.9% |

This was worth measuring because the intuitive reading of the earlier evidence
was wrong. Code-predictor cost *is* flat at ~7.3 ms across all 15 codebook
steps while its KV cache grows 1→15 — but that is not dispatch overhead, it is
that the weight matmuls dwarf attention over a 15-entry cache. Only **7.5%** of
a code-predictor `Run` is spent outside kernels.

**Which weights?** The code-predictor is **fp32, 420 MB**, and a single-token
decode reads essentially all of it per call: 420 MB / 8.06 ms ≈ **52 GB/s**,
i.e. it is bound by streaming its own weights, not by arithmetic intensity.
The talker was already converted to fp16; the code-predictor and vocoder
were not.

## What each option can possibly buy

Amdahl against the 96.4% that is ONNX Runtime, where *k* is the speedup on the
ported portion:

| ported | share | k=3 | k=5 | k=10 | k=∞ |
| --- | --- | --- | --- | --- | --- |
| vocoder only | 9.7% | 1.07× | 1.08× | 1.10× | 1.11× |
| talker only (incl. prefill) | 31.6% | 1.27× | 1.34× | 1.40× | 1.46× |
| code-predictor only | 55.1% | 1.58× | 1.79× | 1.98× | 2.23× |
| talker + code-predictor | 86.7% | 2.37× | 3.26× | 4.55× | 7.52× |
| everything (all three graphs) | 96.4% | 2.80× | **4.37×** | 7.55× | 27.78× |

Against a current RTF of ~1.8 on a quiet machine:

- **Real-time playback (RTF 1.0)** needs ~**1.8×**.
- **MLX parity (RTF 0.4)** needs ~**4.5×**.

So: **no single graph reaches the adopter's reference point, at any speedup.**
Even an infinitely fast code-predictor gives 2.23×, and it is the largest
share. Real-time playback is reachable by porting the code-predictor alone
(1.79× at k=5, against the 1.81× needed — call it borderline). MLX parity needs
either **all three graphs at ≳5.5×**, or **the two decoder graphs at ~10×**
(4.55×). Either way it is a complete second inference backend, not an
accelerator bolted onto the existing one.

That is the honest headline. It should be decided as "do we want an Apple-only
TTS backend?", not as "can we turn on the GPU?".

## Option A — fp16 the code-predictor (do this first)

The code-predictor is **fp32** while the talker was already converted to fp16.
It is 55.1% of wall time, it is bound by streaming its own 420 MB of weights,
and halving those bytes is the most direct lever available.

- **Estimated ceiling:** if fp16 halves the stream time, ~2× on 55.1% of the
  run → **~1.38× overall**, which is most of the way to real-time playback.
  Estimated, not measured — a bandwidth-bound stage should scale close to
  linearly with weight bytes, but that wants confirming rather than assuming.
- **Cost:** a re-export using tooling we already have.
  `Scripts/vendor-qwen-tts.sh` already converts the talker and text-embedding
  to fp16; this extends the same step to the code-predictor (and possibly the
  vocoder, though it is `Conv`-bound rather than bandwidth-bound, so expect
  less).
- **Platform-independent** — it speeds up all five platforms, where a CoreML or
  MLX backend helps exactly one.
- **Risks.** Precision: the sampler is *seeded*, so numerics that drift fork the
  token stream into different-but-plausible speech — reuse v0.10.2's
  `graphOptimizationPreservesAudio` waveform-correlation test as the gate.
  Android: fp16 contrib-op kernels are missing there, which is why that platform
  runs `ORT_ENABLE_BASIC`; a second fp16 graph should be fine under that
  existing constraint but needs device verification, since this is exactly the
  Stable-Diffusion Gelu-fusion failure mode.

### Not: fusing the 15 codebook calls

The earlier draft of this document proposed collapsing the code-predictor's 15
sequential calls into one graph invocation. **The profiling rules that out.**
Only **7.5%** of a code-predictor `Run` is spent outside kernels, so removing
14 of every 15 `Run` boundaries recovers at most ~7.5% of 55.1% ≈ **4% of wall
time** — and that is the optimistic bound, since the fused graph still executes
the same operators.

It is also harder than it looks: `QwenSampler.sampleCP` draws a token **in
Swift between every step**, so fusing means moving top-k + temperature + our
seeded RNG inside the graph, changing both the model contract and our
determinism story. Bad ratio: upstream export work for ~4%.

The same 7.5–10.1% figure caps the other "cheap" idea — ORT IO binding and
reused input buffers. Both target the `Run` boundary, and the `Run` boundary is
not where the time is.

## Option B — CoreML via a native export

Not the EP: a `.mlpackage` per graph, converted with `coremltools`, driven
through the CoreML Swift API.

- **`FluidInference/qwen3-tts-coreml` already exists** — noted in
  [`v0.9-plan.md`](v0.9-plan.md) during the original model survey and never
  evaluated. **Establishing whether it is usable is the cheapest next step in
  this whole document** and should happen before any of the estimates here are
  trusted; it may collapse the export work to zero.
- **Why it can work where the EP can't:** conversion is offline and whole-graph,
  so there are no partition boundaries and no per-run handoff. Dynamic KV-cache
  shapes — the thing that defeated the EP — become bounded enumerated shapes or
  a fixed-capacity cache decided at export time.
- **Risks.** The zero-element first-step KV cache that killed the EP at run time
  is an *export-time* problem here (a fixed-capacity cache with a length mask
  is the standard answer, and changes the graph contract). Enumerated shapes
  mean a compile per shape, so first-run latency and on-disk cache size need
  watching. And CoreML picks its own compute unit: an ANE that silently
  declines an op falls back to CPU, so the backend must report what it got —
  `ai.info().provider` (v0.10.2) is the hook, and would need CoreML-specific
  values.
- **Fit with the repo:** no new SwiftPM dependency (CoreML is a system
  framework), Apple-only, and it slots in as another `AIBackend` behind the
  existing `MultiModelImageBackend`-style routing. This is the conservative
  choice.

## Option C — MLX

MLX Swift (`mlx-swift`) is what the adopter's reference implementation used,
and its GPU kernels are the direct answer to a `MatMul`- and bandwidth-bound
decode.

- **Upside:** the measured 8× came from this stack, so it is the only option
  with a real-world number attached rather than an estimate.
- **Cost:** a **new runtime dependency**, which this repo treats as a
  significant change — it would be the third on-device tier after ONNX Runtime
  and llama.cpp, and would follow llama.cpp's prebuilt-`binaryTarget` pattern.
  It also means porting the model definition to MLX Swift, not just converting
  weights: the talker/code-predictor/vocoder would be hand-written layers, the
  way `SwiftPWAQwenTTS` already hand-writes the tokenizer and sampler.
- **Apple-only**, and macOS/iOS GPU only.

## Recommendation

1. **fp16 the code-predictor** (Option A). Cheapest, uses tooling we already
   have, benefits all five platforms, and attacks the largest single share.
   ~1.38× estimated — worth measuring before anything else is decided.
2. **Evaluate `FluidInference/qwen3-tts-coreml`** (hours). It decides whether
   Option B is "convert three graphs" or "adopt an existing export", and every
   estimate below it is provisional until someone has run it.
3. **Only then** decide B vs C, as an explicit "do we want an Apple-only TTS
   backend?" call. Do not start either expecting an incremental accelerator:
   the numbers say partial ports cannot reach the target.

**Why the GPU is still the endgame.** Single-token decode is `MatMul`-bound and
weight-bandwidth-bound, which is precisely the shape Apple's GPU answers better
than its CPU cores. That is the mechanism behind the adopter's 8×, and neither
fp16 nor any `Run`-boundary tuning changes which processor the matmuls run on.
Options A and B/C are complementary, not alternatives — but A is a fraction of
the cost and should be measured first.

## What this does not change

`ai.generateAudio`, the model download tier, gating and playback are all
unaffected — the adopter confirms none of it changes when a faster provider
lands. Any backend here is an `AIBackend` conformance selected at composition
time, so the JS surface is identical and non-Apple platforms keep the ONNX
path.

## Open questions

- Does fp16 actually halve the code-predictor's time, and does the waveform
  survive it? (Blocks Option A; measurable with tooling in the repo.)
- Is `FluidInference/qwen3-tts-coreml` current, correctly licensed
  (Apache-2.0 upstream), and does it match the 12 Hz 0.6B CustomVoice pipeline
  we ship — including the 9 preset voices?
- Does a CoreML fixed-capacity KV cache preserve output? The sampler is
  **seeded**, so numerics that drift will fork the token stream into
  different-but-plausible speech. v0.10.2's
  `graphOptimizationPreservesAudio` (waveform correlation) is the test to reuse.
- Is the vocoder worth converting too? It is 9.7% and `Conv`-bound rather than
  bandwidth-bound, so fp16 should help less there — but it is the same export
  step, so the marginal cost is near zero.
