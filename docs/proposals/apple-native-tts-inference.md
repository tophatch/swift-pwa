# Proposal: Apple-native inference for on-device TTS (CoreML / MLX)

**Status:** proposal, not scheduled. Written after v0.10.2 measured the ONNX
Runtime CoreML execution provider and found it unusable for this pipeline
([`docs/on-device-ai-performance.md`](../on-device-ai-performance.md)).

> **Every cheap option here has since been measured and ruled out.** What
> remains is a yes/no on an Apple-only TTS backend — see
> [Recommendation](#recommendation).

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

## Option A — fp16 the code-predictor: measured, and it loses

The code-predictor is fp32 and 420 MB while the talker was already fp16, and a
single-token decode streams essentially all of it per call (420 MB / 8.06 ms ≈
52 GB/s). That read said "bandwidth-bound", and predicted ~1.38× overall from
halving the bytes.

**Measured, it is 2× slower.** Converting the code-predictor to fp16
(`onnxruntime.transformers.float16`, `keep_io_types=False`, `op_block_list=[]`
— the same flags `Scripts/vendor-qwen-tts.sh` uses for the talker), feeding
fp16 tensors from Swift, best of 3 warm runs, both sides at `ORT_ENABLE_BASIC`:

| code-predictor | warm wall | speedup |
| --- | --- | --- |
| fp32 (shipping) | 21,595 ms | — |
| fp16 | 41,832 ms | **0.52×** |

**Why.** ONNX Runtime's **CPU** execution provider has no native fp16 kernels
for most of these operators; it emulates them by casting up to fp32, computing,
and casting back. Halving the weight bytes buys nothing when every operator
pays a conversion, and the 52 GB/s figure was a coincidence rather than a
bandwidth ceiling. fp16 is an optimisation for GPU-class execution providers and
for model size — the talker is fp16 for the download budget and for future
accelerator work, not because it is faster on CPU.

The output also **forked**: 140,160 samples against 147,840, so the reduced
precision changed the seeded sampler's path. Even a positive result here would
have needed that resolving.

**A second blocker found on the way.** ONNX Runtime **1.27** — the version we
vendor — cannot even load an fp16 code-predictor at `ORT_ENABLE_ALL`:
`SimplifiedLayerNormFusion` fails with `Attempting to get index by a name which
does not exist: InsertedPrecisionFreeCast_…`, naming a node the graph does not
contain. Reproduced in Python against 1.27 (fails at `ALL`, fine at `BASIC`) and
**fixed by 1.29**. Anyone revisiting fp16 anywhere in this tier needs the
runtime bumped first.

### Also ruled out: fusing the 15 codebook calls

An earlier draft proposed collapsing the code-predictor's 15 sequential calls
into one graph invocation. The profiling rules it out: only **7.5%** of a
code-predictor `Run` is spent outside kernels, so removing 14 of every 15 `Run`
boundaries recovers at most ~7.5% of 55.1% ≈ **4% of wall time** — optimistic,
since the fused graph still executes the same operators.

It is also harder than it looks: `QwenSampler.sampleCP` draws a token **in Swift
between every step**, so fusing means moving top-k, temperature and the seeded
RNG inside the graph, changing both the model contract and our determinism
story. Upstream export work for ~4%.

The same 7.5–10.1% figure caps ORT IO binding and reused input buffers. Both
target the `Run` boundary, and the `Run` boundary is not where the time is.

### What that leaves

Every lever that keeps the work on ONNX Runtime's CPU provider is now measured
and exhausted:

| lever | result |
| --- | --- |
| graph optimization `.basic` → `.all` | **~1.5×, shipped in v0.10.2** |
| fuse the 15 codebook calls | ≤4%, and needs sampling moved into the graph |
| IO binding / buffer reuse | ≤4% (same `Run` boundary) |
| fp16 the code-predictor | **0.52× — actively worse** |

There is no cheap platform-independent win left. The remaining distance is a
different execution engine, which is Option B or C — or accepting the current
speed.

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

The cheap options are gone — measured, not assumed. What remains is a binary
choice, and it should be made as one:

1. **Evaluate `FluidInference/qwen3-tts-coreml`** (hours). It decides whether
   Option B is "convert three graphs" or "adopt an existing export", and it is
   the only remaining cheap step in this document.
2. **Then decide: build an Apple-only TTS backend, or ship at current speed.**
   With v0.10.2's ~1.5× the pipeline runs at roughly 1.8–2.5× slower than real
   time depending on machine load. That is usable for generate-then-play and is
   not usable for streaming playback, which is the adopter's blocker.
3. If yes, **B before C**: CoreML needs no new dependency and no re-implemented
   model, where MLX needs both. C's advantage is that its 8× is observed rather
   than estimated.

**Why the GPU is the only lever left.** Single-token decode is `MatMul`-bound;
the CPU provider computes those matmuls in fp32 and cannot be talked out of it
(fp16 makes it worse, fusion saves 4%). Moving them to the GPU or ANE is the
one change that alters the arithmetic itself, and it is the mechanism behind
the adopter's 8×.

**If the answer is "not now",** say so to the adopter explicitly. Their
read-aloud feature does not ship on the current path, and they should not wait
on a release expecting it to.

## What this does not change

`ai.generateAudio`, the model download tier, gating and playback are all
unaffected — the adopter confirms none of it changes when a faster provider
lands. Any backend here is an `AIBackend` conformance selected at composition
time, so the JS surface is identical and non-Apple platforms keep the ONNX
path.

## Open questions

- **Answered:** fp16 on the code-predictor is 0.52× (2× slower) on the CPU
  provider, and forks the seeded token stream. See Option A.
- ONNX Runtime **1.27** cannot load an fp16 code-predictor at
  `ORT_ENABLE_ALL` (`SimplifiedLayerNormFusion`); **1.29** can. Worth bumping
  the vendored runtime independently of this proposal?
- Is `FluidInference/qwen3-tts-coreml` current, correctly licensed
  (Apache-2.0 upstream), and does it match the 12 Hz 0.6B CustomVoice pipeline
  we ship — including the 9 preset voices?
- Does a CoreML fixed-capacity KV cache preserve output? The sampler is
  **seeded**, so numerics that drift will fork the token stream into
  different-but-plausible speech. v0.10.2's
  `graphOptimizationPreservesAudio` (waveform correlation) is the test to reuse.
- Would an **fp32 talker** be *faster* on CPU, given fp16 is emulated there?
  It is 31.6% of the run and currently fp16 for download size. The reverse
  experiment is cheap, but the payoff is capped around 1.14× and it roughly
  doubles the 846 MB talker download — probably not worth it, recorded so it
  is not re-derived.
