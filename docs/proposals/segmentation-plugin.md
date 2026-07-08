# Proposal: on-device segmentation plugin (`vision.*`)

> **Status: proposal / RFC.** Nothing here is implemented. Written to unblock
> a consumer feature ("Object Select" in Sprites/pixelart) that needs
> promptable on-device image segmentation (SAM-family). The intent is that
> the framework team can build the native side against this contract in
> parallel with the web-side integration. API names/shapes are the decision
> under review — see **Open questions** at the end.

## Motivation

A raster editor wants "tap an object → select it" using on-device ML: run a
segmentation model (MobileSAM / SAM) over the current layer and turn the
returned object mask into an editor selection, with add/subtract semantics.
Everything on-device, no network, both platforms that matter here
(Android arm64 + Apple), consistent with the rest of swift-pwa's
provider-agnostic, opt-in plugin model.

## Why not `ai.*`

`AIPlugin` is a **generative** contract — every `AIBackend` method is
`generate*` (text / JSON / image / audio), request → response (or
request → server-stream). Segmentation is different in two ways that make it
a poor fit for `ai.*`:

1. **It's discriminative, not generative.** It takes an image + a spatial
   prompt (a point or box) and returns *masks*, not tokens or generated
   media. None of `generate`/`generateJSON`/`generateImage`/`generateAudio`
   describes it; forcing it in would mean overloading `generateImage` return
   types or smuggling masks through `generateJSON`, both ugly.
2. **It's stateful across calls (encode-once / decode-many).** SAM splits
   into a *heavy image encoder* (resize → ~1024², a ViT → a 256×64×64
   embedding — essentially all the compute) and a *cheap prompt decoder*
   (point/box + the cached embedding → mask, in milliseconds). Interactive
   use **requires** caching the embedding on the native side across many
   decode calls. Every `ai.*` command today is stateless. This needs a
   **session** primitive.

So this proposes a **sibling plugin, `vision.*`**, in its own optional target
(`SwiftPWASegmentation`), backend-injected exactly like `AIPlugin` — Core
takes on no model-runtime dependency. It reuses every `ai.*` convention:
`ctx.use(...)` opt-in, an `info` capability probe, `ensureModel` for the
downloadable-model tier, `AIImage`-shaped inputs (inline `dataBase64` or
on-disk `path`), and the stable `BridgeError` code scheme.

## JS surface

All via the standard `invoke` / `subscribe`.

```js
// Capability probe — call once, route on `available`.
const info = await __SWIFT_PWA__.invoke('vision.info', {});
// → { available, backend, model?,
//     pointPrompts, boxPrompts, multimask, autoMask,
//     maxImageSize, sessionCaching }
//   backend ∈ none | mobile-sam-onnx | sam-onnx | mobile-sam-candle | …
if (!info.available) { /* hide the ML object-select mode */ }
```

### Session: encode once (the expensive step)

```js
// Runs the image ENCODER and caches the embedding native-side under an
// opaque handle. This is the multi-hundred-ms call — the consumer runs it
// on layer/viewport change, debounced, NOT per interaction.
const { sessionId, width, height } = await __SWIFT_PWA__.invoke(
  'vision.openSession',
  { image: { path: dataDir + '/layer-cache.png' } }   // path, not base64 — see note
);
```

`image` is the same shape as `ai.*`'s `AIImage`: exactly one of
`{ path }` or `{ dataBase64, mimeType }`. **Prefer `path`** — a doc-sized RGBA
layer is large (a 4096² PNG, or worse its base64) should not cross the bridge
as a string on every re-encode. `width`/`height` echo the source pixel dims so
the consumer can map prompt coordinates 1:1.

### Decode: segment at a prompt (the cheap step)

```js
// Runs the DECODER against the cached embedding. Fast (~ms). One per tap.
const { masks } = await __SWIFT_PWA__.invoke('vision.segment', {
  sessionId,
  points: [{ x: 120, y: 84, label: 1 }],   // label 1 = foreground, 0 = background
  box: null,                                // optional [x0,y0,x1,y1] alternative/added prompt
  multimask: true,                          // return the 3 SAM candidates + scores
});
// → masks: [{ bounds:[x0,y0,x1,y1], rle:[...], score }]  (best-first)
```

Coordinates are in **source-image pixels** (the dims returned by
`openSession`); the backend owns the internal resize to the model's input
resolution. `points` accepts multiple prompts (positive + negative) so a
consumer can refine ("this, but not that corner").

### Segment everything (automatic mask generation)

```js
// Grid-of-prompts AMG + NMS → every distinct object as its own mask.
// Heavier; stream progress. Consumer uses this for a "pre-segment
// everything, hover-to-highlight" UX on capable devices.
__SWIFT_PWA__.subscribe('vision.segmentAllStream',
  { sessionId, pointsPerSide: 16, iouThreshold: 0.88, minAreaPx: 16 },
  (e) => {
    if (e.type === 'progress') setBar(e.done, e.total);
    else if (e.type === 'done') useMasks(e.masks); // same mask shape as vision.segment
  });
// Unary vision.segmentAll also provided for small images / one-shot use.
```

### Release

```js
await __SWIFT_PWA__.invoke('vision.closeSession', { sessionId });
```

Sessions also expire on an LRU/idle policy native-side (each cached
embedding is a few MB — 256·64·64·float ≈ 4 MB for SAM); a `segment` against
an evicted/unknown `sessionId` fails with `E_VISION_SESSION` so the consumer
re-opens.

### Mask encoding — `rle` + `bounds`

Each mask is `{ bounds:[x0,y0,x1,y1], rle, score }`:

- `bounds` — tight bbox in source pixels (lets the consumer allocate/scan only
  the touched region; matches the editor's tiled mask model).
- `rle` — **row-major run-length over the `bounds` box**, integer run lengths,
  first run is the count of 0s (background). Compact for the many-masks AMG
  case and for the large sparse masks typical of a sprite on empty canvas;
  trivially decoded in JS into a bitmap/tiled mask. (Rejected alternatives:
  raw base64 bitmap — too big for AMG; PNG path per mask — fine for one mask,
  wasteful for hundreds. If a single huge mask ever needs it, a `pngPath`
  option can be added later without breaking the shape.)
- `score` — model IoU/quality estimate, for ranking and for `multimask`
  disambiguation.

### Benchmark (device-capability gate)

The consumer must decide *at runtime* between an eager "pre-segment
everything" UX (only viable when encode + AMG are fast enough) and a lean
"tap-to-segment" UX. Two ways to support that, propose both:

```js
// Real synthetic timing on a fixed internal test image.
const b = await __SWIFT_PWA__.invoke('vision.benchmark', {});
// → { encodeMs, decodeMs, segmentAllMs, deviceClass: 'high'|'mid'|'low' }
```

Plus `vision.info` MAY carry a coarse `deviceClass` hint. The consumer can
also just time its first real `openSession` + `segment` and cache the verdict
— cheapest and most honest. The proposal's job is to make the timings
*observable*; the policy lives in the app.

### Errors

| code | meaning |
| --- | --- |
| `E_VISION_UNAVAILABLE` | no usable backend (also surfaced by `vision.info`) |
| `E_VISION_SESSION` | unknown/evicted `sessionId` — re-open and retry |
| `E_VISION_SEGMENTATION` | backend available but inference failed |
| `E_VISION_MODEL` | `vision.ensureModel` download failed (network / checksum) |
| `E_UNIMPLEMENTED` | backend doesn't support this command (e.g. `segmentAll`) |

Mirrors the `ai.*` scheme so JS switches on stable codes.

## Swift surface — implementing a backend

```swift
public protocol SegmentationBackend: Sendable {
    func info() async -> VisionCapabilities

    // Required: the encode/decode split.
    func openSession(_ req: OpenSessionRequest) async throws -> VisionSession   // heavy
    func segment(_ req: SegmentRequest) async throws -> SegmentResult           // cheap
    func closeSession(_ id: String) async

    // Default-implemented — override where the runtime can do better:
    func segmentAll(_ req: SegmentAllRequest) async throws -> SegmentResult
    func segmentAllStream(_ req: SegmentAllRequest)
        -> AsyncThrowingStream<VisionProgress, any Error>
    func ensureModel(_ req: AIEnsureModelRequest)          // reuse AI's type
        -> AsyncThrowingStream<AIDownloadEvent, any Error>
    func benchmark() async throws -> VisionBenchmark
}
```

Defaults: `segmentAll` throws `.unsupportedPlatform` (a backend that only does
prompted segmentation is valid — the consumer falls back to tap-to-segment);
`segmentAllStream` wraps `segmentAll` in a single `done`; `ensureModel` throws
`.unsupportedPlatform` (bundled-model backends); `benchmark` runs one synthetic
`openSession` + `segment`. Encoding runs off the main actor (swift-pwa
concurrency model); the embedding is retained in the session, keyed by
`sessionId`, under an LRU cap. Install exactly like `AIPlugin`:

```swift
ctx.use(VisionPlugin(MobileSAMBackend(model: .mobileSAMv2, cacheDirectory: url)))
ctx.use(VisionPlugin())   // NoneBackend → available:false, contract wired
```

## Runtime / model recommendation

The consumer originally pointed at
[`Demonthos/MobileSamGguf`](https://huggingface.co/Demonthos/MobileSamGguf)
(`mobile_sam-tiny-vitt.gguf`, `sam_vit_b_01ec64.gguf`). **Note those ggufs are
candle-format, not llama.cpp** — SAM isn't a llama.cpp architecture, so the
existing `SwiftPWALlama` GGUF path can't load them. Two runtime options:

- **ONNX Runtime + standard MobileSAM ONNX exports (recommended).** SAM's
  canonical mobile deployment is two ONNX graphs (encoder + decoder) — this is
  exactly how SAM's own web demo ships, and the encode/decode split falls out
  for free. ONNX Runtime is **already on swift-pwa's roadmap** (`gemma-onnx`,
  `stable-diffusion-onnx`), so this reuses that runtime investment and gets
  CoreML EP on Apple / NNAPI/XNNPACK on Android. Backend id `mobile-sam-onnx`.
- **candle (Rust) + the linked ggufs.** Matches the exact linked files but adds
  a Rust runtime + C-FFI bridge and its own cross-compile story. Backend id
  `mobile-sam-candle`. Heavier; only worth it if candle lands for other
  reasons.

Either way the model is a Swift-side choice invisible to JS (as with `ai.*`);
`vision.info.backend` reports which one ran.

## Perf / memory notes

- Encoder is the cost (hundreds of ms – low seconds on mobile CPU/NPU for a
  MobileSAM TinyViT); decoder is ~ms. The session cache is what makes it
  interactive — do not re-encode per prompt.
- Embedding ≈ 4 MB/session; cap concurrent sessions (LRU, e.g. 2–3) and expire
  on idle.
- AMG (`segmentAll`) is many decoder passes + NMS — stream progress; expect it
  to be viable only on `deviceClass: high`.
- Domain caveat for the consumer's benefit: SAM is trained on natural photos;
  crisp low-res pixel art is out of domain and results should be validated
  on-device. This is the app's concern, but backends should not assume
  photographic input.

## Open questions (for the team)

1. **Plugin name / namespace.** `vision.*` (proposed) vs folding into `ai.*`
   as `ai.segment*` vs `segment.*`. Recommendation: `vision.*` — leaves room
   for other discriminative vision tasks (detection, depth, OCR-boxes) under
   one analytical namespace, keeps `ai.*` = generative.
2. **Session lifetime & eviction policy** — explicit `closeSession` only, or
   also a TTL? Proposed: both (explicit + idle LRU), with `E_VISION_SESSION`
   as the re-open signal.
3. **Mask format** — is `bounds` + row-major `rle` the right primary? (See
   rationale above.) Add `pngPath` option now or defer?
4. **Benchmark** — ship `vision.benchmark`, or leave device-classing entirely
   to the app's timed warmup? Proposed: ship it but keep it optional.
5. **Box + multi-point refine** in v1, or point-only first? Proposed: v1 =
   single positive point + optional box; multi-point/negative refine fast-
   follow (same request shape, no contract change).
6. **Reuse `AIEnsureModelRequest`/`AIDownloadEvent`** from Core, or define
   vision-local twins? Proposed: reuse — the download machinery
   (`ModelDownloader`, SHA-256-pinned, resumable) is modality-agnostic.

---

## Maintainer evaluation / decision (2026-07-06)

Accepted for **0.8**, with the substance of the proposal largely intact but
two changes: the **namespace**, and how the work is **scoped/sequenced**. This
section is the contract the framework team should build against — where it
differs from the body above, this section wins.

### 1. Namespace: `ai.vision.*`, backed by a *separate* `SegmentationBackend`

The "sibling `vision.*` vs fold into `ai.*`" question is really **two
independent decisions**, and the answer takes one from each side:

- **JS surface → `ai.vision.*`** (not top-level `vision.*`). Consumers have
  already learned that `ai.*` means "on-device model inference"; segmentation
  *is* that, and this proposal already reuses `AIImage`, the
  `ensureModel`/`AIDownloadEvent` download machinery, the capability-probe
  pattern, and the `BridgeError` scheme. A separate top-level family would be
  mostly namespace theater. `ai.vision.*` reads as "the vision subset of the
  on-device-AI family" and leaves room for `ai.vision.detect` / `depth` /
  `ocr` later. So: `ai.vision.info`, `ai.vision.openSession`,
  `ai.vision.segment`, `ai.vision.segmentAll(Stream)`, `ai.vision.closeSession`,
  `ai.vision.ensureModel`, `ai.vision.benchmark`. Error codes keep the
  `E_VISION_*` names (they describe the failure, not the namespace).

- **Swift side → a distinct `SegmentationBackend` in its own optional target
  (`SwiftPWASegmentation`), installed via its own `VisionPlugin(...)`** — as the
  proposal's "Swift surface" section already has it. It is **not** methods on
  `AIBackend`: that protocol is generate-only, and the encode-once/decode-many
  **session** primitive plus the discriminative image→mask shape don't map onto
  any `generate*`. Core takes on no model-runtime dependency; a consumer can opt
  into segmentation without generative AI and vice versa.

Net: **one namespace prefix, two plugins/backends.** This intentionally breaks a
strict "one namespace = one plugin" reading — accepted, because namespaces need
not be 1:1 with plugins and the alternative (a second injected backend on
`AIPlugin`, `AIPlugin(generative:vision:)`) couples two unrelated opt-ins for no
gain. `VisionPlugin` registers its commands under the `ai.vision.` prefix.

### 2. The 0.8 epic is the **ONNX Runtime tier**; segmentation is its first consumer

Runtime decision: **ONNX Runtime**, as recommended (`mobile-sam-onnx`). The
linked ggufs are candle-format — SAM is not a llama.cpp architecture, so
`SwiftPWALlama` cannot load them — and ONNX is SAM's canonical mobile
deployment (encoder + decoder graphs *are* the session split), with CoreML EP
on Apple and NNAPI/XNNPACK on Android. It also reuses the ONNX Runtime
investment already roadmapped for `gemma-onnx` / `stable-diffusion-onnx`, which
is the decisive reason to keep segmentation in the `ai.*` family. The candle
option is dropped for 0.8.

Consequence for planning: **landing ONNX Runtime cross-platform is the long
pole**, not the segmentation contract. Expect llama-0.7.x-style per-platform
linking/cross-compile work (a `.systemLibrary` + env linker-search path off
Apple, prebuilt artifacts, checksum-pin workflows). Therefore **0.8 scope**:

- **In:** the ONNX Runtime backend tier; `ai.vision.info` / `openSession` /
  `segment` (single positive point **+ optional box**) / `closeSession` /
  `ensureModel`; on **Apple + Android** (the platforms the consumer needs).
- **Fast-follow (not 0.8):** `segmentAll`/AMG + `segmentAllStream`,
  `ai.vision.benchmark`, multi-point / negative-point refine, and any desktop
  (Linux/Windows) backend. None of these change the request shapes, so they
  land without a contract break.

### 3. Answers to the open questions

1. **Namespace** — `ai.vision.*` + separate `SegmentationBackend`/target (§1).
2. **Session lifetime** — both, as proposed: explicit `closeSession` **and**
   idle LRU eviction, `E_VISION_SESSION` as the re-open signal.
3. **Mask format** — `bounds` + row-major `rle` is the primary, as proposed.
   **Defer `pngPath`** — add later behind the same shape only if a single huge
   mask ever needs it.
4. **Benchmark** — ship `ai.vision.benchmark` but keep it **optional and
   low-priority** (fast-follow); the primary device-classing path is the app
   timing its own first real `openSession` + `segment` (a fixed synthetic image
   risks being unrepresentative of doc-sized layers).
5. **Prompts in v1** — single positive point + optional box. Multi-point /
   negative refine is a fast-follow with no contract change.
6. **Reuse `AIEnsureModelRequest` / `AIDownloadEvent`** — yes, reuse Core's
   types. (This coupling is itself part of why the `ai.vision.*` naming is the
   honest one.)

### 4. Gaps to close before implementation

- **Cross-platform parity is a documented exception here.** Per the repo's
  parity-by-default rule, state explicitly that Linux/Windows ship a
  `NoneBackend` (`available:false`) in 0.8 — this is a scoped-down exception,
  not an oversight — and note it in the relevant platform docs.
- **iOS vs macOS.** "Apple" must be pinned down: a ViT encoder on an iPhone NPU
  (CoreML EP) is viable but memory-heavy, and the ~4 MB/embedding LRU cap
  interacts with iOS memory limits. Decide iOS in or out for 0.8 explicitly.
- **Model hosting.** MobileSAM weights need a host + SHA-256 pin + resumable
  download story; reuse the llama artifacts' `workflow_dispatch` auto-pin
  pattern rather than inventing a new one.
