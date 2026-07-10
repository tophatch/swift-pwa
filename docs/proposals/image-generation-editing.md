# Proposal: on-device image generation & editing (`ai.generateImage`)

> **Status: in progress, targeting v0.9.0.** Landed + verified on Apple:
> the generalized `ai.generateImage` **contract** (optional `prompt`, new
> `image`/`mask`/`strength`/`guidanceScale`, `AICapabilities.imageEditing`);
> a shared **`SwiftPWAONNX`** target extracted from `SwiftPWASegmentation`
> so backends reuse the ONNX Runtime tier; **`LaMaBackend`**
> (`SwiftPWAImageEdit`) with an Apple `ImageCodec`, a configurable
> `LaMaModelSpec`, resize-to-square + composite-back, and a
> downloadable-model tier; and the **`Scripts/vendor-lama.sh`** +
> **`.github/workflows/lama-vendor.yml`** weights-hosting path.
> **Real-weights pass done (Apple/CPU + Linux/CPU):** the actual big-lama
> fp32 export ran end-to-end on both — the assumed `LaMaModelSpec` (input
> names `image`/`mask`, output `output`, `[0,1]` image, `[0,255]` output,
> **fixed 512² input** — the one correction from the assumed dynamic size)
> is confirmed; a masked block inpaints away and unmasked pixels stay
> pristine. The **`lama-vendor` release is published** (so
> `LaMaBackend(cacheDirectory:)` fetches out of the box), and the **desktop
> (Linux/Windows) `ImageCodec`** is in (stb_image / stb_image_write via
> `CStbImage`) and Linux-verified. The **Android `ImageCodec`** (BitmapFactory
> decode + `Bitmap.compress` encode over the Kotlin RPC — the whole
> `ImageCodec` API is now `async` to accommodate it) is implemented and
> **cross-compile-verified** for `aarch64-unknown-linux-android28`; on-device
> verification on the Tab S10+ is the last step (the project norm for Android,
> since CI can't cross-compile). **Remaining:** Android on-device verify, and
> GPU verification (LaMa reuses the same `OrtModelSession` as the
> CUDA/DirectML-verified segmentation tier, so it's expected to just work).
> Original proposal text below.
>
> **Status (original): proposed, targeting v0.9.0.** The text→image half of the
> `ai.*` contract (`ai.generateImage` / `ai.generateImageStream`,
> `AICapabilities.imageGeneration`) has shipped **contract-only** since
> the v0.7.0 image/audio landing — the request/result/streaming types
> exist, the JS commands are documented, backend IDs are reserved, but
> **no backend implements them** (exactly the TTS story). This proposal
> does two things: **(1)** generalize the existing `ai.generateImage`
> request from "text→image only" to a **purpose-agnostic image op**
> (text→image, image→image, inpaint, outpaint — decided by which fields
> the caller sets, not by a new command per mode), and **(2)** ship the
> first backend against it — **LaMa inpainting on ONNX Runtime**, a
> natural fast-follow to SAM segmentation (SAM makes the mask, LaMa fills
> it), with Stable-Diffusion-class text→image as a heavier follow. See
> **Scoping calls** at the bottom for decisions already made.

## Motivation

Two concrete adopter asks:

- **LaMa inpainting** — erase/fill a region of an existing image. This
  pairs directly with the `ai.vision.*` segmentation tier shipped in
  0.8.x: a tap produces a SAM mask, LaMa consumes it to remove the
  object and reconstruct the background. "Tap to erase" is the demo.
- **Stable Diffusion** (and friends) — text→image, and img2img /
  SD-inpaint as options.

The runtime these ride on — **ONNX Runtime, all five platforms + desktop
CUDA/DirectML GPU EPs** — was fully built out by the v0.8.0–0.8.2 vision
epic. The segmentation proposal explicitly framed ORT as roadmapped for
`gemma-onnx` / `stable-diffusion-onnx` with segmentation as its *first*
consumer. Image generation/editing is the next consumer of that same
investment; no new runtime is needed.

## Design philosophy — one general verb, purpose left to the adopter

The instinct to add `ai.inpaint`, `ai.img2img`, `ai.outpaint` as
separate commands was rejected in favor of **one `ai.generateImage`
whose behavior is defined by which inputs are present**:

| caller supplies | operation |
| --- | --- |
| `prompt` only | text→image |
| `prompt` + `image` | image→image (img2img) |
| `image` + `mask` (± `prompt`) | inpaint — fill the masked region |
| `image` + `mask`, mask covers a border | outpaint / uncrop |

This keeps the contract **purpose-agnostic and extendable**: a new
capability (say, ControlNet-style conditioning, or a depth map) is a new
*optional field*, not a new command and not a bridge change. It also
keeps the maintenance surface small — one command, one streaming
variant, one result type across every image backend anyone writes.

Crucially: **the backend and model are a Swift-side / adopter choice,
invisible to JS** — exactly as `ai.*` text and `ai.vision.*` already
work (`info.backend` reports *which* ran; JS never names a model). The
backends **we** ship (LaMa, later SD) are **examples of the contract,
not doctrine**. An adopter is free to wire a different model, a
different purpose, or a private checkpoint behind the same `ai.*`
surface; nothing in the contract presumes Stable Diffusion or LaMa
specifically.

## Contract changes — additive, all optional

Extend the **existing** `AIGenerateImageRequest`
([Sources/SwiftPWACore/Plugin/AI.swift](../../Sources/SwiftPWACore/Plugin/AI.swift))
with optional fields; keep `AIGeneratedImage` / `AIGenerateImageResult`
/ `AIImageEvent` **unchanged** (an edited image is just a generated
image). The only mildly breaking change is `prompt: String` →
`prompt: String?` (LaMa is prompt-free), and there is no shipped backend
reading it yet, so the blast radius is zero.

```swift
public struct AIGenerateImageRequest: Sendable, Codable, Equatable {
    public var prompt: String?          // was `String` — now optional (LaMa needs none)
    public var negativePrompt: String?
    public var width: Int?
    public var height: Int?
    public var steps: Int?
    public var seed: Int?
    public var count: Int?
    public var outputDirectory: String?

    // --- new, all optional; presence selects the operation ---
    /// Source / init image. Its presence turns text→image into
    /// image→image (or, with `mask`, an inpaint). Inline base64 or an
    /// on-disk `path` — the same `AIImage` used for vision input, so a
    /// big image never crosses the bridge as base64 when a path will do.
    public var image: AIImage?
    /// Edit mask (grayscale). By convention **white = edit this region,
    /// black = keep**. Requires `image`. Same `AIImage` carrier.
    public var mask: AIImage?
    /// img2img denoising strength (0…1): how far to deviate from `image`.
    /// Ignored by pure-inpaint (LaMa) and text→image backends.
    public var strength: Double?
    /// Classifier-free-guidance scale (SD-family knob). Optional; the
    /// backend chooses a default and a prompt-free backend ignores it.
    public var guidanceScale: Double?
}
```

Capabilities stay two small orthogonal booleans on `AICapabilities` —
extendable, non-rigid:

```swift
public let imageGeneration: Bool   // text→image (existing)
public let imageEditing: Bool      // accepts `image` (± `mask`) — img2img / inpaint (new)
```

A LaMa backend reports `imageEditing: true` and can leave
`imageGeneration: false` (it doesn't do text→image). An SD backend can
report both. A consumer probes `ai.info` to decide which affordances to
show; it never hard-codes a backend name.

## JS surface

No new command — `ai.generateImage` / `ai.generateImageStream` gain
optional fields. All existing text→image call sites are unchanged.

```js
// Inpaint (LaMa): erase what the mask covers, no prompt.
const { images } = await __SWIFT_PWA__.invoke('ai.generateImage', {
    image: { path: dataDir + '/photo.jpg' },
    mask:  { path: dataDir + '/mask.png' },        // white = remove
    outputDirectory: dataDir + '/edited',          // omit for inline base64
});
// → images: [{ path?|dataBase64?, mimeType, seed }]

// img2img (SD): re-imagine an image under a prompt.
await __SWIFT_PWA__.invoke('ai.generateImage', {
    prompt: 'a watercolor version', image: { path: src }, strength: 0.6,
});

// text→image (SD) — unchanged from today.
await __SWIFT_PWA__.invoke('ai.generateImage', { prompt: 'a fox', width: 512, height: 512 });
```

Streaming is unchanged: `ai.generateImageStream` emits `progress`
(denoising step + optional `preview`) then `done`. LaMa is single-pass,
so it inherits the default wrapper (one `done`); SD overrides to report
per-step progress.

## Example: the SAM → inpaint pipeline

The headline pairing, shipped as an **example** (extend
`Examples/CritterFacts`' existing tap-to-segment page into tap-to-erase),
not as contract:

1. `ai.vision.segment` at a tap → an RLE mask + `bounds`
   ([the shipped 0.8 vision tier](segmentation-plugin.md)).
2. Decode the RLE to a full-image grayscale PNG (white over the selected
   pixels). This is a small, pure step — candidate for a JS helper in
   the example, or a native `ai.vision` convenience returning a mask
   image directly (see Open questions).
3. `ai.generateImage({ image, mask })` → the object is gone, background
   reconstructed.

Both halves are on-device, both ride ONNX Runtime, and the mask handoff
is just an `AIImage`.

## Runtime / model recommendation

All choices are Swift-side and invisible to JS; the backend id is
reported by `info.backend`. Reserved ids already in `AIBackendID`:
`apple-image-playground`, `stable-diffusion-mlx`, `stable-diffusion-onnx`,
`stable-diffusion-mediapipe`. This proposal adds `lama-onnx`.

- **First backend — LaMa on ONNX Runtime (`lama-onnx`).** Small,
  prompt-free, single forward pass (image + mask → image), a canonical
  ONNX export exists, and it reuses the *entire* shipped ORT tier
  (`OrtRuntime`/`OrtModelSession`, image decode, preprocessing, the
  CUDA/DirectML desktop GPU EPs, the `ModelDownloader` +
  `ai.ensureModel` weight-fetch story). Lowest-risk first consumer and
  the natural SAM fast-follow. Downloadable-model tier off a
  `lama-vendor`-style release, mirroring `mobilesam-vendor`.
- **Follow — Stable Diffusion.** Heavier (multi-model pipeline: text
  encoder + UNet + VAE, iterative denoising, tokenizer). Two runtime
  routes, matching the text tiers' pattern: **`stable-diffusion-onnx`**
  (reuses the ORT tier again; cross-platform) and/or
  **`stable-diffusion-mlx`** (Apple-fast). Scoped as a separate
  increment after LaMa proves the extended contract.

## Backwards compatibility

- `ai.generateImage({ prompt })` — unchanged.
- New request fields are all optional; old clients omit them.
- Result/streaming types are byte-for-byte the same.
- `prompt: String → String?` is the only signature change; no shipped
  backend consumes `prompt` today, so nothing breaks. Text-conditioned
  backends validate presence and throw `E_AI_GENERATION` on a missing
  prompt.
- `imageEditing` defaults to `false`, so existing (hypothetical) backends
  and `AICapabilities` call sites are source-compatible.

## Open questions (for the team)

1. **Mask carrier / RLE bridge.** Ship the SAM-RLE→mask-PNG conversion
   as a JS example helper, or add a native convenience (e.g. an
   `ai.vision` option to return the mask as an `AIImage` directly)?
   Leaning example-first; promote to native only if adopters ask.
2. **Mask polarity default.** White = edit is the SD/LaMa web
   convention; worth an explicit `invertMask` escape hatch, or leave it
   to the caller to pre-invert? Leaning: document the convention, no
   flag until asked.
3. **`imageEditing` granularity.** Two booleans
   (`imageGeneration` / `imageEditing`) vs. a richer descriptor of
   supported modes. Per the "don't be rigid" stance, start with the two
   booleans and let a descriptor grow only if a real backend needs to
   advertise a mode a boolean can't express.
4. **Session/caching.** SD keeps large models resident; does image gen
   want an encode-once *session* like `ai.vision.*`, or is per-call load
   acceptable for v1? Leaning per-call for LaMa (cheap), revisit for SD.

## Out of scope (this proposal)

- **Stable Diffusion itself** — reserved and sketched above, but a
  separate increment after LaMa validates the extended contract.
- **Platform-built-in image gen** (Apple Image Playground / any OS
  txt2img) — id reserved (`apple-image-playground`); not part of the
  first cut.
- **ControlNet / depth / pose conditioning** — the contract is designed
  to absorb these as future optional fields, but none ship here.
- **Video / animation.**

## Scoping calls (2026-07-10)

Decisions taken with the maintainer before drafting code:

1. **One general `ai.generateImage`, not per-mode commands.** The
   operation is selected by which optional fields are present
   (`prompt` / `image` / `mask`). Rationale: purpose-agnostic,
   extendable via new optional fields, single maintenance surface. The
   alternative (a dedicated `ai.inpaint`/`ai.editImage`) was considered
   and rejected as narrower and higher-maintenance.
2. **Model and purpose are the adopter's choice; our backends are
   examples, not doctrine.** The contract presumes no specific model.
   LaMa and (later) SD are reference backends demonstrating the surface;
   an adopter can wire any model/purpose behind the same `ai.*` JS API.
3. **Ship order: LaMa inpainting first** (small, prompt-free, reuses the
   shipped ORT tier, pairs with SAM), **SD as a follow.**
4. **Additive/optional contract changes only**, with the single
   `prompt: String → String?` relaxation (zero blast radius today).
