# Proposal: image-generation adopter refinements — model selection & granular download progress

> **Status: Part 2 implemented (Unreleased); Part 1 proposed.** Two additive,
> backwards-compatible refinements to the on-device image tier
> (`ai.generateImage` / `ai.ensureModel`), surfaced while an adopter built a
> text→image feature on `StableDiffusionBackend` (v0.8.5 / v0.8.6). Neither is a
> blocker — the adopter shipped around both — but each is a rough edge hit the
> moment you offer more than one model or download a multi-GB model on Android.
> They're unrelated in mechanism but share one origin (an adopter driving the
> image tier hard), hence one doc.
>
> 1. **A model selector on `ai.generateImage`** (+ a `models` list on `ai.info`),
>    so a *running* app can choose among several image backends — today the model
>    is fixed at backend init, so a live switcher is impossible without an app
>    restart. The switcher spans not just several *local* model files but
>    **local and remote backends** (an on-device ONNX model vs a cloud image
>    API), which the end user picks from a dropdown based on need — speed/offline
>    vs quality/licence. See [Local + remote, one dropdown](#local--remote-one-dropdown).
> 2. **Byte-level download progress on Android**, so `ai.ensureModel` for a
>    multi-GB model reports a smooth bar instead of stepping once per file.

## Context — how an adopter hit both

An adopter (a pixel-art editor on the swift-pwa shell) added prompt→image generation
backed by `StableDiffusionBackend`, composing it with `LaMaBackend` (inpaint)
behind one `AIPlugin` via an adopter-side `CompositeImageBackend` that routes
`generateImage` by request shape (a source `image` ⇒ inpaint/LaMa, a bare prompt
⇒ text→image/SD) — the "one `ai.*` surface, several purposes" pattern
`Examples/CritterFacts` demonstrates.

That worked. Two things did not have a clean answer:

- **The team ships two text→image models** — SD-Turbo (non-commercial) and, since
  v0.8.6, **LCM_Dreamshaper** (OpenRAIL-M, commercial-usable) — and their real goal
  is broader still: a dropdown where the end user switches between **local and
  remote backends** (an on-device ONNX model vs a cloud image API) *based on need* —
  offline/fast/free on-device vs higher-quality/paid/online in the cloud. A pro
  tool wants to let the user pick (quality vs licence vs download size vs
  connectivity). There is no way to express "generate *this* one with LCM" (let
  alone "with the cloud backend") at call time, so the adopter had to hard-pick one
  model at build time (LCM) and drop the switcher.
- **The LCM download is ~2 GB across 5 files**, dominated by a single 1.72 GB UNet
  (83% of the total). On the Galaxy Tab S10+ the download bar jumped `0% → 12%
  (text encoder done) →` a long silent stall on the UNet `→ ~95% → done`, because
  Android reports progress once per file, not per byte.

---

## Part 1 — model selection for `ai.generateImage`

### Problem

`AIGenerateImageRequest` (v0.8.6) has no way to name a model:

```swift
public struct AIGenerateImageRequest {
    public var prompt: String?
    public var negativePrompt: String?
    public var width, height, steps, seed, count: Int?   // (abridged)
    public var outputDirectory: String?
    public var image: AIImage?      // present ⇒ edit/inpaint
    public var mask: AIImage?
    public var strength, guidanceScale: Double?
    // …no `model`.
}
```

and each `StableDiffusionBackend` / `LaMaBackend` **binds one model at init**
(`source` + `spec`). So a live "generate with LCM vs SD-Turbo" switch is
impossible: the choice is fixed when `AIPlugin` is installed. `ai.ensureModel`
*does* take a `model` hint (a string the adopter's composite routes on), so the
download path is already model-aware — but generation is not, which is
asymmetric.

`ai.info` also reports a single `model: String?`, so JS can't populate a
switcher or tell the user which models exist / are downloaded.

### Proposed contract change (additive, optional)

Two additions, both nil-safe so every current caller is unaffected:

**a. `model` on the request** — which model to use; `nil` = the backend's default
(current behavior).

```swift
public struct AIGenerateImageRequest {
    // …existing…
    /// Which installed image model to use (an id from `AICapabilities.models`).
    /// `nil` ⇒ the backend's default. Honored by a backend that hosts more than
    /// one model (or an adopter composite that routes on it); single-model
    /// backends ignore it.
    public var model: String?
}
```

Mirror it on `generateImageStream`. `ai.generateAudio` could take the same field
later for symmetry, but that's out of scope here.

**b. `models` on `AICapabilities`** — so `ai.info` advertises what's available:

```swift
/// Runtime availability of a model, unified across local and remote.
/// A `downloaded: Bool` + `sizeBytes` pair can't express a cloud model
/// (never "downloaded", no size) or a backend that needs setup, so
/// availability is an enum rather than a flag.
public enum AIModelAvailability: Sendable, Codable, Equatable {
    case ready                        // usable now: remote reachable, or local + on disk
    case downloadable(bytes: Int64?)  // local, not yet fetched → ai.ensureModel
    case needsSetup(reason: String)   // e.g. missing API key, offline, region-locked
}

/// What a model can do, as a set rather than a fixed pair of bools — so one
/// model list can carry text, image, vision, and audio backends alike, and new
/// purposes are added without a struct change. Covers the standard multimodal
/// capabilities the `ai.*` / `ai.vision.*` surfaces already span. Raw values are
/// the strings JS sees (`model.capabilities.includes('inpaint')`).
public enum AIModelCapability: String, Sendable, Codable {
    // Text
    case textGeneration  = "text-generation"   // chat / completion (llama, Foundation Models, Gemini Nano, Phi Silica)
    case textEmbedding   = "text-embedding"    // vectors for RAG / semantic search
    // Image out
    case imageGeneration = "image-generation"  // text→image (SD-Turbo / LCM)
    case imageEdit       = "image-edit"         // img2img / prompt+image
    case inpaint         = "inpaint"            // image+mask (LaMa)
    // Image in
    case vision          = "vision"             // image understanding: segmentation (MobileSAM), detection, OCR, captioning
    // Audio
    case speechToText    = "speech-to-text"     // transcription / ASR
    case textToSpeech    = "text-to-speech"     // TTS (the ai.generateAudio contract)
    case audioGeneration = "audio-generation"   // music / sfx / general audio
    // extensible; a model lists every purpose it serves
}

public struct AIModelInfo: Sendable, Codable, Equatable {
    public let id: String            // stable id, e.g. "lcm-dreamshaper" / "cloud-sdxl"
    public let label: String         // human-facing, e.g. "LCM Dreamshaper"
    public let capabilities: Set<AIModelCapability>
    public let availability: AIModelAvailability
    public let offlineCapable: Bool  // on-device (no network) vs cloud — badges the picker
    public let license: String?      // e.g. "OpenRAIL-M", "Stability Non-Commercial"
}

public struct AICapabilities {
    // …existing single `model: String?` stays (the active/default)…
    /// The models this backend can serve, when it hosts more than one.
    /// `nil` (or one entry) ⇒ single-model, no switcher needed.
    public var models: [AIModelInfo]?
}
```

The info is deliberately **modality-agnostic** — an `AIModelInfo`, not an
`AIImageModelInfo` — because the switcher the user wants is "pick a backend based
on need," and those backends span modalities: text (Foundation Models, llama.cpp,
Gemini Nano, Phi Silica), image (SD/LCM, LaMa), vision (MobileSAM), audio (the TTS
contract). One model list, one picker.

Four fields earn their place beyond `id`/`label`:

- **`capabilities`** is a `Set<AIModelCapability>` rather than the earlier
  `imageGeneration`/`imageEditing` bool pair. A set expresses "does both",
  distinguishes `inpaint` (image+mask) from a free `imageEdit` (img2img) — the very
  request shapes the tier already routes on — and covers the full standard
  multimodal spread (`textGeneration`, `vision`, `textToSpeech`, `speechToText`, …)
  without a struct change as new purposes land. (A *map* keyed by capability would
  only pay off once each capability carried detail — max resolution, max context;
  until then a set is the honest shape, and the map is a clean later extension.)
  The enum is a **shared vocabulary**, not tied to one plugin: the `ai.vision.*`
  surface is a separate `SegmentationBackend`/`VisionPlugin` with its own
  `ai.vision.info`, but it can advertise `vision` from the same enum, so a
  cross-surface picker presents on-device text/image/vision/audio models together
  even though they sit behind different plugins.
- **`availability`** replaces a plain `downloaded: Bool`/`sizeBytes` pair. Those
  two are local-download concepts — a remote model is never "downloaded" and has
  no size, and a cloud backend can be *present but unusable* (no API key, offline).
  The enum expresses all three states a mixed local+remote picker must render:
  ready now, needs a (sized) download, or needs setup.
- **`offlineCapable`** lets the picker badge on-device vs cloud — the exact axis
  the user switches on ("fast/offline/free" vs "higher-quality/online/paid").
- **`license`** an adopter shipping commercially filters non-commercial models out
  of the picker (exactly the adopter's SD-Turbo problem).

### Who routes — keep it the adopter's job

Consistent with the tier's design philosophy ("one general verb, purpose left to
the adopter" — see [image-generation-editing.md](image-generation-editing.md)),
the framework need not host multiple models in one backend. The minimal, in-ethos
version:

- The **contract** gains `request.model` + `info.models` (above).
- **Routing stays in the adopter's composite** — the same place `CompositeAIBackend`
  already routes `generateImage` by shape and `ensureModel` by hint. It would hold
  N backends and switch on `request.model`, and aggregate their `info().models`
  into the list. No framework backend needs to become multi-model.

### Local + remote, one dropdown

The switcher's headline case isn't two ONNX files — it's **local vs remote**. This
falls out of the design for free, because **a remote image API is just another
`AIBackend`**: a conformer whose `generateImage` issues an HTTPS call instead of
running ONNX. The composite routes to it by the same `request.model` string. So a
dropdown offering "LCM (on-device)" and "SDXL (cloud)" is one composite over
`[ "lcm-dreamshaper": StableDiffusionBackend(...), "cloud-sdxl": MyRemoteBackend(...) ]`,
and the string id names *a route* — which may be a whole backend, local or remote —
not merely a weights file.

This is also why model ids **must be free strings, not a framework enum** (see
[Open questions](#open-questions-for-the-team)): a remote service's model namespace
is defined by that service, and `ensureModel`'s existing `model` hint is already a
free string — the two should share one namespace.

Because every adopter with a switcher then writes the *identical* router (hold
`[id: AIBackend]`, switch `generateImage`/`generateImageStream` on `request.model`,
aggregate each child's `info().models`, forward `ensureModel` by id), a small
**`MultiModelImageBackend`** helper should **ship in-framework** rather than be
left to each adopter. It's the same "compose backends behind one `ai.*` surface"
pattern `CompositeAIBackend` demonstrates example-side, promoted to a supported
type once a real adopter needs local+remote. (The contract doesn't *require* it —
an adopter can still hand-roll the composite — but shipping it is what makes
local+remote turnkey instead of boilerplate.)

### JS surface

```js
const info = await bridge.invoke('ai.info', {})
// info.models → [{ id, label, imageGeneration, imageEditing,
//                  availability, offlineCapable, license }]
// availability is one of:
//   { ready: true }
//   { downloadable: { bytes: 1720180719 } }   // local, needs ai.ensureModel
//   { needsSetup: { reason: "Add an API key in Settings" } }

// download a local model on demand (ai.ensureModel already takes `model`)
bridge.subscribe('ai.ensureModel', { model: 'lcm-dreamshaper' }, onProgress)

// generate with a chosen route — may be an on-device model or a cloud backend
await bridge.invoke('ai.generateImage', { prompt, model: 'lcm-dreamshaper' })
await bridge.invoke('ai.generateImage', { prompt, model: 'cloud-sdxl' })
```

A picker is then just `info.models` — filtered by `imageGeneration` and, for a
commercial app, `license`; each row badged on-device/cloud via `offlineCapable`;
and its affordance driven by `availability` (usable now, a sized download, or a
"needs setup" prompt). Because a cloud model's availability changes at runtime
(connectivity, an added API key), the app re-probes `ai.info` on those events
rather than reading it once at launch — see [Open questions](#open-questions-for-the-team).

### Backwards compatibility

Fully additive. `request.model == nil` and `info.models == nil` reproduce today's
single-model behavior exactly; no shipped backend or page changes. `ai.info`'s
existing scalar `model` stays as "the active/default model."

---

## Part 2 — granular (byte-level) download progress on Android

> **✅ Implemented (Unreleased).** Shipped via the **events-bus (host-event
> channel)** option below: `net.downloadFile` takes an optional `channel`, the
> Kotlin read loop pushes throttled ~1 MiB `{ bytesDone, totalBytes }` frames,
> and a shared `AndroidFileDownload.download(…)` helper (now used by all three
> model backends) forwards them to the `ensureModel` stream. Backward compatible
> (absent `channel` ⇒ old per-file behavior). See CHANGELOG.

### Problem

`ai.ensureModel` for a multi-file model sums the file sizes into **one aggregate
`bytesDone / totalBytes` bar**. On **Apple/desktop** the per-file download
(`ModelDownloader.ensure`) has a **byte-level callback**, so the bar is smooth. On
**Android** the download routes through the Kotlin `net.downloadFile` RPC (Swift's
URLSession has no injectable CA store there), and that RPC **reports only per
file** — `StableDiffusionBackend.ensureModel` can therefore only `yield` once per
file, at each file's *start*, with the cumulative bytes of the files already done:

```swift
// Android branch (abridged)
for file in files {
    continuation.yield(.progress(bytesDone: base, totalBytes: grandTotal)) // once, at file start
    _ = try await AndroidRPC.call("net.downloadFile", …)                   // no byte callback
}
```

For LCM (5 files, 1.72 GB UNet = 83% of ~2.07 GB) that yields a stair-step:
`0% → 12%` (text encoder done) `→` **long silent stall on the UNet** `→ ~95% →
done`. The user sees the bar freeze at 12% for the entire UNet download — reads as
a hang, not progress.

### Proposal

Give the Kotlin `net.downloadFile` RPC a **progress channel** so it emits
periodic byte counts during a download, and have the Android `ensureModel` branch
forward them as sub-file `.progress` events (offsetting by `base`, exactly as the
Apple path forwards `downloader.ensure`'s callback). Result: parity with
Apple/desktop — a smoothly-advancing bar on-device.

Implementation options for the progress channel (the RPC is request/response
today):

- **Emit progress on the events bus** — the Kotlin side posts
  `net.downloadFile.progress` events (`{ requestId, bytesDone, totalBytes }`)
  during the read loop; the Swift caller subscribes for the duration of the call.
  Reuses the existing events plumbing.
- **A streaming RPC variant** — `net.downloadFileStream` yielding progress frames
  then a terminal done, mirroring the shape `ai.ensureModel` already exposes to JS.

Either way the Kotlin `HttpURLConnection` read loop **already streams bytes**
(it computes the SHA-256 incrementally), so it's a matter of surfacing a count
every N bytes / ~100 ms across the boundary — no new download logic.

### Interim (adopter-side, no framework change)

An adopter can soften the UX today by treating a long-stalled bar as busy — e.g.
copy like "Downloading model — one-time ~2 GB, this can take a minute." The
adopter may do this regardless; it's not a substitute for real byte progress.

### Backwards compatibility

Additive. Callers that don't subscribe to the progress channel see the current
per-file behavior. Apple/desktop paths are unchanged (already byte-level).

---

## Out of scope

- Multi-model *hosting inside one framework backend* (the proposal keeps routing
  in the composite; the recommended `MultiModelImageBackend` helper is still a
  router over N single-purpose backends, not a backend that itself loads N models).
- *Shipping* a remote backend. The proposal makes remote a first-class *routing*
  target (it's just an `AIBackend`), but a concrete cloud backend is the adopter's
  to write against their chosen API — the framework ships no HTTP image client.
- Progress for anything other than `net.downloadFile` (though the same events-bus
  pattern would generalize).
- A model *download manager* UI — that's the adopter's (`ai.info.models` +
  `ai.ensureModel` give it what it needs).

## Open questions (for the team)

- **Model id source of truth.** *Leaning: free strings.* An enum the framework
  owns can't name a remote service's models, and `ensureModel`'s existing `model`
  hint is already a free string — one namespace, adopter-defined, keeps it in step
  with "purpose left to the adopter." Only open point is whether to reserve a few
  well-known ids the shipped backends advertise by default.
- **`models` on `ai.info` vs a dedicated `ai.listModels`.** *Leaning: keep it on
  `ai.info`, but make it cheap to re-probe.* One probe is simpler, and the
  local+remote case doesn't need a separate command — it needs `ai.info` to be
  re-callable, because a cloud model's `availability` flips at runtime
  (connectivity, an added API key) and the picker must react. A dedicated
  `ai.listModels` only earns its place if the list itself grows large or churns.
- **Progress channel shape.** Events bus vs streaming RPC — which fits the Android
  bridge conventions better long-term? (Independent of Part 1; only affects local
  downloads, which remote backends skip.)
