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

**2. The pipeline is op-dispatch bound, not compute bound.** Per-call cost of
the code-predictor, averaged over 73 frames:

```text
group  1: 12.81 ms      <- feeds 2 tokens, builds KV from empty
group  2:  7.28 ms
group  3:  7.24 ms
...
group 15:  7.29 ms
```

**Flat.** The KV cache grows from 1 to 15 entries across those calls and the
time does not move, so attention over the cache is not what's being paid for.
Normalising by graph size says the same thing from the other side: the talker
is 2,629 nodes at 37 ms (**14 µs/node**) and the code-predictor 721 nodes at
7.3 ms (**10 µs/node**) — near-identical per-node cost across two very
differently-shaped graphs. That is the signature of per-operator dispatch
overhead, not of matmuls.

This explains the CoreML EP result rather than contradicting it. A runtime
already spending its time on per-op overhead gets *worse* when you add 170
partition boundaries to it. It also explains the MLX number: MLX's win on this
shape is lazy evaluation plus kernel fusion collapsing thousands of tiny
dispatches, not raw GPU FLOPs.

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

## Option A — fewer calls, same runtime (do this first)

Before any port: the 1,095 code-predictor invocations are the single largest
cost, and they are *overhead*, not work. Collapsing the 15 sequential codebook
steps into one graph invocation per frame would remove ~14/15 of that overhead.

- **Ceiling:** ~2.2× if the fused call costs what one step costs today; less in
  practice. Enough for real-time playback, not for MLX parity.
- **Cost:** a re-export, not new Swift. The 15 steps are a loop over codebooks
  inside the code-predictor; whether it can be expressed as one graph
  (a scan/loop op, or a batched form) is an **open question for whoever owns
  the export**, and is the first thing to establish.
- **Why it ranks first anyway:** it is platform-independent. It speeds up
  Android, Linux and Windows by the same proportion, where a CoreML or MLX
  backend helps exactly one platform. It also shrinks the portion a later port
  would need to cover.

The same argument applies more weakly to the talker (73 calls; inherently
sequential, so there is nothing to fuse).

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

MLX Swift (`mlx-swift`) is what the adopter's reference implementation used, and
its lazy-eval + fusion model is the direct answer to a dispatch-bound workload.

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

1. **Evaluate `FluidInference/qwen3-tts-coreml`** (hours, not days). It decides
   whether Option B is "convert three graphs" or "adopt an existing export",
   and every estimate above is provisional until someone has run it.
2. **Ask the export owner whether the code-predictor's 15 steps can be one
   graph call** (Option A). Cheapest real win, helps all five platforms, and
   reduces whatever a later port has to cover.
3. **Only then** decide B vs C, as an explicit "Apple-only TTS backend" call.
   Do not start either expecting an incremental accelerator: the numbers say
   partial ports cannot reach the target.

## What this does not change

`ai.generateAudio`, the model download tier, gating and playback are all
unaffected — the adopter confirms none of it changes when a faster provider
lands. Any backend here is an `AIBackend` conformance selected at composition
time, so the JS surface is identical and non-Apple platforms keep the ONNX
path.

## Open questions

- Can the code-predictor's codebook loop be expressed as a single graph
  invocation? (Blocks Option A; needs the export owner.)
- Is `FluidInference/qwen3-tts-coreml` current, correctly licensed
  (Apache-2.0 upstream), and does it match the 12 Hz 0.6B CustomVoice pipeline
  we ship — including the 9 preset voices?
- Does a CoreML fixed-capacity KV cache preserve output? The sampler is
  **seeded**, so numerics that drift will fork the token stream into
  different-but-plausible speech. v0.10.2's
  `graphOptimizationPreservesAudio` (waveform correlation) is the test to reuse.
- Is per-op dispatch overhead partly ours? ORT is being handed one `Run` per
  step with freshly-built input tensors; IO binding and reused buffers might
  recover some of the 10 µs/node without any port. **Untested, and cheap to
  test** — worth a measurement before committing to anything above.
