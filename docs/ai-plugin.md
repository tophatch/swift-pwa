# On-device AI plugin (`ai.*`)

`AIPlugin` puts LLM inference behind the bridge so the web layer stays
provider-agnostic: the page asks `ai.*` for text or schema-constrained
JSON, and *where* that runs — a platform built-in model, a bundled small
model, or (the app's own) cloud fallback — is a Swift-side decision the
page never has to encode.

It is an **opt-in plugin** (like `fs.*` / `dialog.*`), not auto-installed:
an app calls `ctx.use(AIPlugin(...))` and supplies the backend.

**New here?** Start with the hands-on tutorial —
[On-device AI (text and images)](tutorials/on-device-ai.md) — which walks
through using a packaged backend, bringing your own model, writing your own
`AIBackend`, and baking a LoRA into an on-device image model. This document
is the full reference behind it.

> **Status (0.7).** The full JS contract, the `AIBackend` protocol, the
> shared structured-output fallback, and `NoneBackend` all ship. The first
> real backend — **Apple Foundation Models** (`SwiftPWAFoundationModels`) —
> is implemented and verified end-to-end on-device (text, token streaming,
> and native schema-constrained `generateJSON`). The remaining per-platform
> backends (Gemini Nano, Phi Silica, the portable Gemma fallback, and the
> image/audio backends) are the roadmap below. A page integrates against
> the frozen contract once and lights up on whatever backend is injected.

## JS surface

All via the standard `invoke` / `subscribe` — there's no `ai`-specific JS
sugar.

```js
// Capability probe — cheap, call once at startup and route on `available`.
const info = await __SWIFT_PWA__.invoke('ai.info', {});
// → { available, backend, model?, streaming, structuredOutput,
//     vision, imageGeneration, audioInput, audioGeneration, voiceCloning,
//     models?, provider? }
//   backend ∈ none | apple-foundation-models | gemini-nano | phi-silica
//           | gemma-mlx | gemma-mediapipe | gemma-onnx | gemma-llamacpp
//           | apple-image-playground | stable-diffusion-mlx
//           | apple-speech | whisper-mlx | tts-mlx | multi-model | …
//   models? → present when a switcher is installed; see "A runtime model /
//             backend switcher" below.
if (!info.available) {
    // fall back to your own (e.g. cloud) tier
}
// Capability flags gate the modalities:
//   vision          → image input honored      imageGeneration → text→image
//   audioInput      → audio input honored       audioGeneration → text→audio
//   voiceCloning    → referenceAudio/-Text honored on ai.generateAudio(Stream)
// provider? → which execution provider an ONNX-tier backend actually loaded on
//   ("cpu" | "coreml" | "cuda" | "directml"); absent until a session exists,
//   and on backends that don't model it. Diagnostic, not a routing signal: an
//   accelerator that fails to initialize falls back to CPU transparently, so
//   this is the only way to tell a working GPU/CoreML build from a silent
//   fallback. The vision surface reports the same field on ai.vision.info.

// One-shot text.
const { text, backend } = await __SWIFT_PWA__.invoke('ai.generate', {
    system: '…optional system prompt…',
    prompt: '…user prompt…',
    maxTokens: 512, temperature: 0.5,   // both optional
});

// One-shot structured generation — returns a parsed, schema-valid object.
const obj = await __SWIFT_PWA__.invoke('ai.generateJSON', {
    system: '…', prompt: '…',
    schema: { type: 'object', required: ['summary'], properties: { /* … */ } },
    maxTokens: 512, temperature: 0.5,
});

// Streaming text — `delta` chunks, then a terminal `done`.
const unsub = __SWIFT_PWA__.subscribe('ai.generateStream', { prompt }, (e) => {
    if (e.type === 'delta') appendToken(e.text);
    else if (e.type === 'done') finish();
});
```

### Vision (image input)

When `info.vision` is true, attach `images` to any of `ai.generate` /
`ai.generateJSON` / `ai.generateStream`. Each image is either inline
base64 or a filesystem `path` the backend reads directly — use `path` for
large on-disk images so the bytes don't cross the bridge as a ~1.33×
base64 string (the same reason `fs.extractZip` is path-to-path). Provide
exactly one of `dataBase64` / `path` per image.

```js
const { text } = await __SWIFT_PWA__.invoke('ai.generate', {
    prompt: 'Describe this image.',
    images: [
        { dataBase64: canvasPngBase64, mimeType: 'image/png' }, // small / canvas
        { path: '/path/to/photo.jpg' },                         // large on disk
    ],
});

// Vision + structured output compose — extract typed fields from a photo:
const receipt = await __SWIFT_PWA__.invoke('ai.generateJSON', {
    prompt: 'Extract the receipt fields.',
    images: [{ path: '/scan.png' }],
    schema: { type: 'object', required: ['total', 'date'] },
});
```

A backend that reports `vision: false` ignores `images`.

> Not to be confused with **`ai.vision.*`** — a separate, discriminative
> plugin (promptable image *segmentation*, not generative image
> understanding) installed via `VisionPlugin`, not `AIPlugin`. See
> [docs/javascript-api.md](javascript-api.md#aivision--promptable-on-device-image-segmentation)
> and [docs/proposals/segmentation-plugin.md](proposals/segmentation-plugin.md).

### Image generation & editing (`ai.generateImage`)

`ai.generateImage` is a **single, purpose-agnostic image op** — the
operation is chosen by *which fields you send*, not by a separate command:

| you send | operation | capability |
| --- | --- | --- |
| `prompt` | text→image | `imageGeneration` |
| `prompt` + `image` | image→image (img2img) | `imageEditing` |
| `image` + `mask` (± `prompt`) | inpaint — fill the masked region | `imageEditing` |

The **model and the operation are a backend choice, invisible to JS** — a
page checks `info.imageGeneration` / `info.imageEditing` to decide which
affordances to show and never names a model. The backends we ship (LaMa
inpainting; Stable-Diffusion-class text→image as a follow) are *examples*
of the contract, not the contract itself — wire your own model behind the
same surface.

Supply an `outputDirectory` to have results **written to disk** and get
back file paths (bridge-efficient — multi-MB image bytes don't cross as
base64; mount the directory with `serveDirectory` to show them); omit it
to get base64 bytes inline (fine for a single small image).

```js
// text→image
const { images, backend } = await __SWIFT_PWA__.invoke('ai.generateImage', {
    prompt: 'a watercolor fox', negativePrompt: 'blurry',
    width: 512, height: 512, steps: 20, seed: 42, count: 1,
    guidanceScale: 7.5,
    outputDirectory: dataDir + '/generated',   // omit for inline base64
});
// → images: [{ path?|dataBase64?, mimeType, seed }], backend

// inpaint (prompt-free, e.g. LaMa) — mask convention: white = edit, black = keep.
// Pairs with ai.vision.* segmentation: the SAM mask becomes the edit mask.
await __SWIFT_PWA__.invoke('ai.generateImage', {
    image: { path: dataDir + '/photo.jpg' },
    mask:  { path: dataDir + '/mask.png' },
    outputDirectory: dataDir + '/edited',
});

// img2img — re-imagine an image under a prompt; `strength` (0…1) = how far to deviate.
await __SWIFT_PWA__.invoke('ai.generateImage', {
    prompt: 'a watercolor version', image: { path: src }, strength: 0.6,
});

// Streaming — denoising-step progress with optional intermediate previews.
// (Single-pass backends like LaMa emit one `done`.)
__SWIFT_PWA__.subscribe('ai.generateImageStream', { prompt }, (e) => {
    if (e.type === 'progress') setBar(e.step, e.totalSteps); // e.preview? optional
    else if (e.type === 'done') show(e.images);
});
```

### Audio input (phoneme evaluation, transcription)

When `info.audioInput` is true, attach `audio` to any text command — the
exact same shape as vision's `images`. Each clip is inline base64 or an
on-disk `path`. The page can record with the WebView's own `MediaRecorder`
(no native audio plumbing needed) and pass the blob; combine with a schema
to get a structured pronunciation assessment back.

```js
const assessment = await __SWIFT_PWA__.invoke('ai.generateJSON', {
    prompt: 'Score the pronunciation of "kiitos".',
    audio: [{ path: dataDir + '/utterance.wav', mimeType: 'audio/wav' }],
    schema: { type: 'object', required: ['overallScore', 'phonemes'] },
});
// → { overallScore, phonemes: [{ symbol, score }, …] }   (shape is yours)
```

### Audio generation (text-to-audio / TTS)

When `info.audioGeneration` is true, `ai.generateAudio` turns text into
audio (speak a word, read a passage). Like image generation: supply an
`outputDirectory` to get a written file `path`, or omit it for inline
base64. The streaming variant emits play-as-it-arrives `chunk`s.

```js
const { audio } = await __SWIFT_PWA__.invoke('ai.generateAudio', {
    prompt: 'kiitos', voice: 'fi-female', language: 'fi-FI', speed: 0.9,
    format: 'wav', outputDirectory: dataDir + '/tts',   // omit for inline base64
});
// → audio: { path?|dataBase64?, mimeType, durationMs }

__SWIFT_PWA__.subscribe('ai.generateAudioStream', { prompt }, (e) => {
    if (e.type === 'chunk') enqueue(e.dataBase64);  // play incrementally
    else if (e.type === 'done') finish(e.audio);
});
```

When `info.voiceCloning` is true, pass `referenceAudio` (inline `dataBase64` or
on-disk `path`) + `referenceText` to clone a voice per request — see
[the worked example](#worked-example-a-custom-on-device-audio-tts-backend) for
the backend side.

> **A shipped TTS backend: `SwiftPWAQwenTTS`.** The `ai.generateAudio` contract
> above is served on-device by an opt-in backend built on the shared ONNX
> Runtime tier (same as the Stable-Diffusion / LaMa image backends) —
> **Qwen3-TTS** (`Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice`, Apache-2.0). Wire it
> with `ctx.use(AIPlugin(QwenTTSBackend(modelDirectory: url)))`, where `url` is
> a directory laid out like the ONNX export (the three graphs — talker,
> code-predictor, vocoder — at the root, plus `embeddings/` and `tokenizer/`
> subdirs). It reports `audioGeneration: true`, synthesizes 24 kHz mono WAV, and
> offers **9 preset voices** via the `voice` field (ryan/serena/vivian/uncle_fu/
> aiden/ono_anna/sohee/eric/dylan) with a `language` selector. Shipping precision
> is fp16 talker + fp32 code-predictor + fp32 vocoder + fp16 text-embedding
> (~2.5 GB). Fetch it with the checksum-pinned **`ai.ensureModel`** download tier
> — `QwenTTSBackend(cacheDirectory: url)` fetches the `qwen-tts-vendor`-published
> pipeline into `url` on first use (like the image backends' downloadable tier) —
> or point `QwenTTSBackend(modelDirectory: url)` at a directory you staged
> yourself. Voice *cloning* (arbitrary reference audio) needs the Base model and
> isn't wired yet, so this backend reports `voiceCloning: false`.
>
> **Memory.** Synthesis peaks around **3 GB RSS** on-device — the talker +
> code-predictor sessions are co-resident through the autoregressive loop, and
> the fp16 talker appears to expand toward fp32 in the ONNX Runtime CPU arena.
> Pass **`lowMemory: true`** (default on the example's Android build) to evict
> the talker + code-predictor before the vocoder loads, so the vocoder doesn't
> stack on top (the spike that OOM-kills the app when a large LLM is also
> resident). That caps the *peak* but not the ~3 GB AR-loop *base*. **Future
> trim lever** (not yet done): shrink that base — e.g. keep the talker fp16 at
> runtime (avoid the CPU-arena fp32 expansion) or run the two talker graphs in a
> shared session — for tighter-RAM devices. Fine on ≥8 GB devices today.
>
> **Speed.** Expect a real-time factor around **2.5** on an M-series Mac — i.e.
> six seconds of speech takes ~15 seconds to synthesize — so this is
> generate-then-play, not streaming playback. Sessions run on the ONNX Runtime
> **CPU** execution provider on every platform; CoreML is plumbed
> (`QwenTTSBackend(coreML:)`) but off by default because it is measurably slower
> for an autoregressive decoder, and mostly refuses to load at all. Benchmark,
> numbers, and the reasoning: [on-device AI
> performance](on-device-ai-performance.md).
>
> **Live, continuous audio streaming** (push mic frames into an open
> session for real-time incremental results) is **not** part of this
> contract — the bridge is request → server-stream-out, with no
> client→server push mid-subscription. That needs a bridge-level
> bidirectional session primitive (a roadmap item, see below); the interim
> pattern is web-side `MediaRecorder` timeslices → repeated `ai.generateJSON`
> calls. Discrete record-then-evaluate (the phoneme-eval case) needs none
> of that.

### Errors

Failures cross the bridge as a `BridgeError` with a stable `code`:

| code | meaning |
| --- | --- |
| `E_AI_UNAVAILABLE` | no usable backend (also reported ahead of time by `ai.info`) — fall back to your own tier |
| `E_AI_GENERATION` | the backend was available but generation failed |
| `E_AI_STRUCTURED_OUTPUT` | `ai.generateJSON` couldn't get schema-valid JSON, even after a repair attempt |
| `E_AI_MODEL` | `ai.ensureModel` download failed — network error or checksum mismatch |
| `E_UNIMPLEMENTED` | the backend doesn't support this command (e.g. `ai.ensureModel` on a platform-built-in backend) |

### `ai.ensureModel`

`subscribe('ai.ensureModel', { model? }, …)` makes a downloadable model
present, streaming `progress` events (`bytesDone` / `totalBytes`) then
`done`. It's for the downloadable-model tier (llama.cpp / the Gemma
fallback); a backend that uses only a platform built-in (Foundation
Models) throws `E_UNIMPLEMENTED`.

The download machinery ships now as `ModelDownloader`
(`SwiftPWAModelStore`): resumable (HTTP `Range`), SHA-256-pinned, cached on
disk with atomic rename, reused across launches. A downloadable backend
keeps a registry of model specs and drives it from its `ensureModel`; the
command lights up for JS once such a backend is installed. Failures
surface as `E_AI_MODEL` (network error or checksum mismatch).

### A runtime model / backend switcher

To let the user pick among several models at runtime — including a mix of
**local and remote** backends (an on-device model vs a cloud API) — pass
`model` on `ai.generateImage` and read the `models` catalog from `ai.info`:

```js
const { models } = await __SWIFT_PWA__.invoke('ai.info', {});
// models: [{ id, label, capabilities, availability, offlineCapable, license }]
//   capabilities ⊂ text-generation | image-generation | image-edit | inpaint |
//                  vision | speech-to-text | text-to-speech | audio-generation | text-embedding
//   availability = { kind: "ready" }
//                | { kind: "downloadable", bytes }   // fetch with ai.ensureModel
//                | { kind: "needsSetup", reason }     // e.g. missing API key / offline

// Build a picker (filter by capability and, for a commercial app, license):
const choices = models.filter(m => m.capabilities.includes('image-generation'));

// Generate with the chosen route (may be on-device or cloud):
await __SWIFT_PWA__.invoke('ai.generateImage', { prompt, model: 'lcm-dreamshaper' });
```

`model: null` (or omitted) uses the backend's default, so single-model apps
need no changes. A cloud model's `availability` can flip at runtime
(connectivity, an added API key), so re-probe `ai.info` on those events rather
than reading it once at launch.

On the Swift side, compose the models behind one `ai.*` surface with
**`MultiModelImageBackend`** (in `SwiftPWACore`) — the shipped router that every
multi-model adopter would otherwise hand-write:

```swift
let switcher = MultiModelImageBackend(
    [
        .init(AIModelInfo(id: "lcm-dreamshaper", label: "LCM Dreamshaper",
                          capabilities: [.imageGeneration, .imageEdit],
                          availability: .downloadable(bytes: 2_067_793_994),
                          offlineCapable: true, license: "OpenRAIL-M"),
              StableDiffusionBackend(cacheDirectory: dir, source: .lcmDreamshaperFp16,
                                     spec: .lcmDreamshaperFp16)),
        .init(AIModelInfo(id: "cloud-sdxl", label: "SDXL (cloud)",
                          capabilities: [.imageGeneration],
                          availability: .needsSetup(reason: "Add an API key in Settings"),
                          offlineCapable: false, license: "commercial"),
              MyRemoteImageBackend(apiKey: key)),   // just another AIBackend
    ],
    default: "lcm-dreamshaper"
)
ctx.use(AIPlugin(switcher))
```

It routes `generateImage` / `generateImageStream` / `ensureModel` by
`request.model`, delegates the text/audio verbs to the default, and aggregates
each entry's `AIModelInfo` into `ai.info`'s `models`. An unknown `model` id
fails with `E_AI_GENERATION` rather than silently falling back.

**Memory — one model resident at a time.** On-device image models are large (a
fp16 Stable-Diffusion pipeline is ~2 GB of session weights). When a generate
routes to a *different* model than last time, `MultiModelImageBackend` first
calls `unload()` on the previously-active backend, freeing its sessions before
the new one loads — otherwise loading a second ~2 GB model while the first is
still resident OOM-kills the app on a phone. `unload()` is a new `AIBackend`
method (default no-op; `StableDiffusionBackend` / `LaMaBackend` implement it to
release their ONNX sessions). If you write a session-caching backend, implement
`unload()`; a remote backend inherits the no-op.

**Freeing the model proactively — `ai.unload` + `system.memoryPressure`.** The
per-switch eviction above only fires when the *model* changes. To free the
resident model at other times — after a one-off generation, or when the OS is
under memory pressure — JS can call **`ai.unload`**, which invokes the backend's
`unload()` (routed through `MultiModelImageBackend` to free every entry). Wire it
to the OS pressure signal so a background app sheds its ~2 GB pipeline before the
kernel starts killing processes:

```js
// Free the on-device model when the OS reports memory pressure, and after a
// run. `ai.unload` is a no-op for backends that cache nothing.
__SWIFT_PWA__.on('system.memoryPressure', ({ level }) => {
    if (level === 'critical') __SWIFT_PWA__.invoke('ai.unload').catch(() => {});
});
await __SWIFT_PWA__.invoke('ai.generateImage', { prompt });
await __SWIFT_PWA__.invoke('ai.unload'); // done with it — give the RAM back
```

**Low-memory mode for constrained devices.** Even one resident pipeline can OOM
mid-run on a phone: the VAE decode's memory spike stacks on top of the ~1.7 GB
UNet held from the denoise loop. `StableDiffusionBackend(…, lowMemory: true)`
evicts the text-encoder after text-encoding and the UNet immediately before VAE
decode, so the UNet is freed *ahead of* the spike rather than under it. It trades
per-run graph-reparse latency for a much lower peak — default `false` (desktop
keeps the resident-cache speed); turn it on for mobile builds.

## Swift surface — implementing a backend

A backend conforms to `AIBackend` (in `SwiftPWACore`, dependency-free).
Only two members are required:

```swift
public protocol AIBackend: Sendable {
    func info() async -> AICapabilities
    func generate(_ request: AIGenerateRequest) async throws -> AIGenerateResult

    // Default-implemented — override only when you can do better:
    func generateStream(_ request: AIGenerateRequest) -> AsyncThrowingStream<AIChunk, any Error>
    func generateJSON(_ request: AIGenerateJSONRequest) async throws -> JSONValue
    func ensureModel(_ request: AIEnsureModelRequest) -> AsyncThrowingStream<AIDownloadEvent, any Error>
    func generateImage(_ request: AIGenerateImageRequest) async throws -> AIGenerateImageResult
    func generateImageStream(_ request: AIGenerateImageRequest) -> AsyncThrowingStream<AIImageEvent, any Error>
    func generateAudio(_ request: AIGenerateAudioRequest) async throws -> AIGenerateAudioResult
    func generateAudioStream(_ request: AIGenerateAudioRequest) -> AsyncThrowingStream<AIAudioChunk, any Error>
}
```

The defaults mean a minimal backend (just `info` + `generate`) gets the
whole `ai.*` command set:

- **`generateStream`** defaults to running `generate` and emitting its
  result as a single `delta` + `done`. Override it when your runtime can
  stream tokens incrementally.
- **`generateJSON`** defaults to the **shared structured-output fallback**
  (below). Override it when your runtime can constrain decoding to a
  schema (then set `structuredOutput: true` in `info()`).
- **`ensureModel`** defaults to throwing `.unsupportedPlatform`. Override
  it only for the downloadable-model tier.
- **`generateImage`** defaults to throwing `.unsupportedPlatform`. Override
  it for an image backend and set the flag(s) that match what it reads from
  the request: `imageGeneration: true` if it honors `prompt` (text→image),
  `imageEditing: true` if it honors `image` (± `mask`) for img2img / inpaint
  — a prompt-free inpainter reports `imageEditing` alone. Validate a
  required `prompt`'s presence and throw `.generationFailed` if a
  text-conditioned request arrives without one.
- **`generateImageStream`** defaults to wrapping `generateImage` in a
  single `done`. Override it to report per-step denoising progress (a
  single-pass backend like LaMa keeps the default).
- **`generateAudio`** defaults to throwing `.unsupportedPlatform`. Override
  it for a TTS / generative-audio backend (then set `audioGeneration: true`).
- **`generateAudioStream`** defaults to wrapping `generateAudio` in a
  single `done`. Override it to emit incremental audio chunks.

**Vision and audio input** need no protocol method — they're the `images`
and `audio` fields on the existing requests. A multimodal backend reads
`request.images` / `request.audio` (each an inline `dataBase64` or an
on-disk `path`) and sets `vision` / `audioInput`; others ignore them.

Throw `AIError` from a backend — the plugin maps each case to the stable
bridge code above (`.unavailable` → `E_AI_UNAVAILABLE`, etc.) at both the
unary and streaming boundaries.

Install it:

```swift
runtime.run { ctx in
    ctx.use(AIPlugin(MyBackend()))   // a real backend, or…
    ctx.use(AIPlugin())              // NoneBackend — contract wired, available:false
}
```

### Worked example: a custom on-device audio (TTS) backend

No shipping backend implements audio yet — the contract is complete and tested,
but wiring an actual synthesizer (CoreML, MLX, or any in-process engine) is
yours to do. This is the full recipe; the JS side
([Audio generation](#audio-generation-text-to-audio--tts)) and the streaming
frames already exist, so you only implement two methods and flip one capability
flag.

**1. Advertise the capability.** `ai.info` must report `audioGeneration: true`
so the page routes to you instead of a fallback tier:

```swift
func info() async -> AICapabilities {
    AICapabilities(
        available: true,
        backend: AIBackendID.ttsMLX,   // or your own id string
        model: "kokoro-82M",
        streaming: true,
        audioGeneration: true
    )
}
```

**2. Implement `generateAudioStream`** — this is the important one; it maps
directly onto the page's play-as-it-arrives `AudioWorklet` ring buffer. Emit
`AIAudioChunk.chunk(_:mimeType:)` as your engine produces PCM, then a single
terminal `AIAudioChunk.done(audio:backend:)`:

```swift
func generateAudioStream(_ request: AIGenerateAudioRequest)
    -> AsyncThrowingStream<AIAudioChunk, any Error>
{
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                let engine = try self.loadEngine()                 // CoreML / MLX model
                let voice = request.voice ?? "default"             // see below
                var assembled = Data()

                // Your synthesizer's per-frame callback. `pcm` is raw bytes in a
                // known format — here 16-bit little-endian mono @ 24 kHz.
                for try await pcm in engine.synthesize(request.prompt, voice: voice,
                                                       speed: request.speed ?? 1.0) {
                    if Task.isCancelled { break }
                    assembled.append(pcm)
                    continuation.yield(.chunk(pcm.base64EncodedString(),
                                              mimeType: "audio/pcm;rate=24000;encoding=signed-int;bits=16;channels=1"))
                }

                // Terminal frame carries the fully assembled clip (inline, or a
                // written file `path` if the request set `outputDirectory`).
                let final = AIGeneratedAudio(dataBase64: assembled.base64EncodedString(),
                                             mimeType: "audio/wav",
                                             durationMs: engine.lastDurationMs)
                continuation.yield(.done(audio: final, backend: AIBackendID.ttsMLX))
                continuation.finish()
            } catch {
                continuation.finish(throwing: AIError.generationFailed("\(error)"))
            }
        }
        continuation.onTermination = { _ in task.cancel() }   // stop synth on unsubscribe
    }
}
```

**3. Implement `generateAudio`** for the one-shot case (or synthesize fully and
return). If you only care about streaming, the simplest correct unary impl
drains your own stream:

```swift
func generateAudio(_ request: AIGenerateAudioRequest) async throws -> AIGenerateAudioResult {
    for try await chunk in generateAudioStream(request) where chunk.type == "done" {
        if let audio = chunk.audio {
            return AIGenerateAudioResult(audio: audio, backend: AIBackendID.ttsMLX)
        }
    }
    throw AIError.generationFailed("no audio produced")
}
```

**Framing.** `AIAudioChunk` deliberately doesn't carry sample-rate / bit-depth /
channel fields — that metadata lives *in* the bytes and is hinted by
`mimeType`. Pick one convention and keep it consistent across `chunk`s so the
page's `AudioWorklet` can configure its ring buffer once. Two common choices:

- **Raw PCM chunks** (lowest latency): each `chunk` is headerless PCM; the page
  needs to know the rate/format out-of-band (encode it in the `mimeType` as
  above, or agree on a fixed format). The terminal `done` can still carry a
  proper `audio/wav` (with header) for save-to-file.
- **Self-describing chunks**: each `chunk` is a complete container (e.g. an Ogg
  page). Simpler for the page, slightly more overhead.

**Voice selection.** `request.voice` / `request.language` / `request.speed`
are on `AIGenerateAudioRequest` — map `voice` to your engine's voice id.

**Reference-audio voice cloning.** `AIGenerateAudioRequest.referenceAudio`
(an `AIAudio` — inline `dataBase64` or on-disk `path`) plus
`referenceText` (its transcript) carry a per-request cloning voice. Report
`voiceCloning: true` in your `AICapabilities` when you honor them; pages route
on `info.voiceCloning` to show a "clone a voice" affordance only where it works.
Because the reference rides on the request, the voice is a user-switchable
preference that changes per call with **no backend re-init** — read it in
`generateAudioStream` and pass it to your engine's cloning path:

```swift
func info() async -> AICapabilities {
    AICapabilities(available: true, backend: "my-tts",
                   audioGeneration: true, voiceCloning: true)
}

func generateAudioStream(_ request: AIGenerateAudioRequest)
    -> AsyncThrowingStream<AIAudioChunk, any Error>
{
    // Resolve the optional reference clip → engine speaker embedding.
    let speaker = request.referenceAudio.map { ref in
        engine.cloneVoice(from: ref.path ?? decode(ref.dataBase64),
                          transcript: request.referenceText)
    }
    // …synthesize request.prompt in `speaker` (or the default voice when nil).
}
```

Backends that don't advertise `voiceCloning` should simply ignore the two
fields — they're optional and default to nil, so older backends stay
source-compatible.

**Model download.** If your model is downloadable, override `ensureModel` and
drive `ModelDownloader` (`SwiftPWAModelStore`) — resumable, SHA-256-pinned,
cached across launches — exactly as the llama backend does; see its source for a
worked `ensureModel`.

**Runtime choices.** For the engine itself, MLX Swift (`mlx-swift`) or CoreML
are the usual on-device options on Apple platforms; both run in-process, so the
result is a self-contained, notarizable `.app` with no sidecar process. If you
need to ship before that's ready, the [subprocess plugin](process-plugin.md)
lets you stream PCM out of an existing Python synthesizer through
`process.stream` with the *same* page-side ring-buffer code, then swap to this
`AIBackend` later without touching the page.

### Bringing your own ONNX model (`SwiftPWAONNX`)

If your model is an **ONNX** graph, you don't need to vendor ONNX Runtime
yourself — the shared wrapper the built-in image/vision backends run on is a
public product. Add `SwiftPWAONNX` to your app's dependencies (it links the
per-platform ONNX Runtime — Apple xcframework / Android AAR / desktop CUDA ·
DirectML · CPU EPs — behind the same `ai.local_onnx_runtime` opt-in in your
`pwa.json`), then drive an arbitrary graph directly:

```swift
import SwiftPWAONNX

let session = try OrtModelSession(modelPath: modelURL.path, runtime: OrtRuntime())
let out = try session.run(
    inputs: ["input": .float(pixels, shape: [1, 3, 518, 518])],  // OrtInput: .float / .float16 / .int32 / .int64
    outputNames: ["depth"]
)
let depth = out["depth"]!.values   // [Float], row-major — your post-processing
```

Wrap that in your own `AIBackend` (or a plain `Plugin` exposing an `ai.depth.*`
command), fetch the weights with `ModelDownloader` (`SwiftPWAModelStore`, also a
public product), and the whole feature lives app-side — no upstream backend
needed per model. The shipped `SwiftPWASegmentation` / `SwiftPWAImageEdit` /
`SwiftPWAStableDiffusion` backends are just larger examples of this same
pattern. `OrtModelSession` accepts fp32/fp16 and integer input tensors and reads
fp16 outputs back as float32; see its API for the exact `Tensor` / `OrtInput`
shapes.

### Available backend: Apple Foundation Models

`SwiftPWAFoundationModels` ships the first real backend — Apple's on-device
system model (Apple Intelligence). Add the product, then:

```swift
import SwiftPWAFoundationModels

runtime.run { ctx in
    ctx.use(AIPlugin(FoundationModelsBackend()))
}
```

It provides text, token streaming, and **native schema-constrained**
`generateJSON` (via Foundation Models guided generation — it maps the JSON
Schema to a `GenerationSchema`, so `structuredOutput` is `true`, not the
prompt fallback). It reports `available: false` (app falls back to its own
tier) when built against an older SDK, run below macOS 26 / iOS 26, or when
the system model isn't ready (unsupported device, Apple Intelligence off,
still downloading). The base system model is text-only, so vision / image /
audio stay off. It's isolated in its own target so apps that don't want
on-device AI never link the FoundationModels framework.

### Available backend: llama.cpp

`SwiftPWALlama` runs a GGUF model on-device via [llama.cpp](https://github.com/ggml-org/llama.cpp)
(**Metal**-accelerated on Apple, **Vulkan** on Linux and Windows x64, **CPU** on
Windows arm64) — the portable counterpart to Foundation Models, usable
independent of OS-level model availability. **Apple (macOS / iOS), Linux
(x86_64), and Windows (x64 Vulkan + arm64 CPU)** today. On Windows **arm64**
(Snapdragon X Copilot+) it's also the unpackaged, any-GGUF, no-token fallback to
[Phi Silica](#available-backend-windows-phi-silica), which needs MSIX + a LAF
token to generate.

It's **off by default** because it links a prebuilt llama binary
(~tens of MB). Turn it on per app in `pwa.json`:

```json
{
  "ai": { "local_llama": true }
}
```

`swift-pwa build --target macos` (or `ios`, `linux`, `windows`) sees that flag
and sets `SWIFT_PWA_LLAMA=1` for the underlying build, pulling in the
`SwiftPWALlama` product. **On Apple** SwiftPM resolves a prebuilt
`.binaryTarget` xcframework (Metal), downloaded + checksum-verified once and
cached across projects. **On Linux and Windows** there's no binary-library
target, so the CLI fetches the prebuilt static lib (Vulkan — `libllama.a` on
Linux, `llama.lib` on Windows) from the swift-pwa release, checksum-verifies +
caches it, and points the build at it via the linker search-path env var
(`LIBRARY_PATH` on Linux, `LIB` on Windows — the same trick `CWebView2Shim`
uses; the headers ship in-tree as a `.systemLibrary`, so no `unsafeFlags`).
When the flag is unset neither is in the package graph — non-AI adopters never
resolve it. (Building the generated app with bare `swift build` instead of
`swift-pwa build` won't include llama unless you export `SWIFT_PWA_LLAMA=1`
yourself — and off Apple also point the linker env var at a directory
containing the static lib, or set `SWIFT_PWA_LLAMA_LINUX_LIB_DIR` /
`SWIFT_PWA_LLAMA_WINDOWS_LIB_DIR` to it.) Linux needs `libvulkan-dev` and
Windows **x64** the Vulkan SDK's `vulkan-1.lib` to link, plus a Vulkan 1.2+
driver/ICD at runtime; Windows **arm64** is CPU-only, so it needs neither (it
links `llama.lib` alone) — see
[docs/linux-setup.md](linux-setup.md#7-optional--on-device-ai-llamacpp-vulkan)
and [docs/windows-setup.md](windows-setup.md#4-optional--on-device-ai-llamacpp).

Then wire the backend, pointing it at a model:

```swift
import SwiftPWALlama

runtime.run { ctx in
    // A GGUF already on disk:
    ctx.use(AIPlugin(LlamaBackend(modelPath: "/path/to/model.gguf")))

    // …or a downloadable model wired to ai.ensureModel (resumable,
    // checksum-pinned via ModelDownloader; the page calls ai.ensureModel
    // before its first ai.generate):
    let spec = ModelSpec(
        url: URL(string: "https://example.com/model.gguf")!,
        sha256: "…", fileName: "model.gguf"
    )
    ctx.use(AIPlugin(LlamaBackend(model: spec, cacheDirectory: modelsDir)))
}
```

It provides text, token streaming, and **native schema-constrained**
`generateJSON`: the request's JSON Schema is compiled to a
[GBNF](https://github.com/ggml-org/llama.cpp/blob/master/grammars/README.md)
grammar that constrains decoding (`structuredOutput: true`). The supported
subset is object (`properties` / `required`), array (`items`), `string`
(incl. `enum`), `integer`, `number`, `boolean`, `null`; a schema using a
construct outside it (e.g. `anyOf`, `$ref`) transparently falls back to the
shared prompt-and-validate path so the command still works. Text-only for
now, so vision / image / audio stay off.

### Available backend: Android Gemini Nano

`GeminiNanoBackend` is the **Android** platform built-in — the on-device
Gemini Nano model exposed through [ML Kit GenAI's Prompt API](https://developers.google.com/ml-kit/genai/prompt/android)
(backed by AICore). It's the Android counterpart to Apple Foundation Models:
no app-shipped weights, free, private, on-device. It ships **inside the Android
backend** (`SwiftPWAAndroid`), so it's available via `import SwiftPWA` — no
separate product to add.

Turn it on per app in `pwa.json`:

```json
{
  "ai": { "gemini_nano": true }
}
```

`swift-pwa build --target android` sees that flag and (a) adds the
`com.google.mlkit:genai-prompt` Gradle dependency to the generated scaffold and
(b) splices the `ai.gemini.*` Kotlin dispatch that the backend RPCs into. Then
wire it (guard with `#if os(Android)` so the same `App.swift` still builds for
your desktop targets):

```swift
import SwiftPWA

runtime.run { ctx in
    #if os(Android)
        ctx.use(AIPlugin(GeminiNanoBackend()))
    #endif
}
```

It provides text (`generate`), **true token streaming** (`generateStream`, via
ML Kit's `generateContentStream`), and on-demand model download
(`ensureModel`). The model is managed by AICore — `info()` reports
`available: true` whenever the device can serve it, **including the
not-yet-downloaded state**, so a page routes on `available` and triggers the
one-time fetch via `ai.ensureModel` (same stance as the downloadable-llama
tier). Only a device without AICore / Gemini Nano reports `available: false`.
Structured output uses the shared prompt-and-validate fallback
(`structuredOutput: false`) for now; the base model is text-only, so vision /
image / audio stay off.

Without `gemini_nano: true` the Kotlin dispatch isn't generated, so the RPCs
resolve to "unknown method" and the backend reports `available: false` — wiring
`GeminiNanoBackend()` is harmless either way, the app just falls back to its own
tier as it would on an unsupported device. Device support, the `adb` debug
loop, and the ML Kit beta caveats live in
[docs/android-setup.md](android-setup.md#9-on-device-ai-gemini-nano).

### Available backend: Windows Phi Silica

`PhiSilicaBackend` is the **Windows** platform built-in — the on-device Phi
Silica model via the [Windows AI APIs](https://learn.microsoft.com/windows/ai/apis/phi-silica)
(`LanguageModel`) in the **Windows App SDK**. The Windows counterpart to Apple
Foundation Models / Android Gemini Nano: system-managed model (pre-installed on
Copilot+ NPU PCs), free, private, on-device.

It's **off by default** because — unlike the built-in-WinRT toast/biometric
shims — it links the Windows App SDK (cppwinrt projection + the unpackaged-app
bootstrapper). Turn it on per app:

```json
{ "ai": { "phi_silica": true } }
```

`swift-pwa build --target windows` then sets `SWIFT_PWA_PHI_SILICA=1` (pulling
in the env-gated `SwiftPWAPhiSilica` target + its `CPhiSilica` C++/WinRT shim)
and the MSIX manifest generator declares the required `systemAIModels`
restricted capability. Wire it (guard with `#if os(Windows)`):

```swift
import SwiftPWAPhiSilica

runtime.run { ctx in
    #if os(Windows)
        ctx.use(AIPlugin(PhiSilicaBackend(unlockToken: myLAFToken)))
    #endif
}
```

It provides text (`generate`), token streaming (`generateStream`), and
on-demand model readiness (`ensureModel`). `info()` reports `available: true`
when the model is `Ready` or merely needs a one-time `EnsureReadyAsync`; only an
unsupported/locked config reports `false`. Structured output uses the shared
prompt-and-validate fallback for now (`structuredOutput: false`); text-only.

> **Two Windows-platform requirements (not swift-pwa's doing).** The Windows AI
> APIs require **MSIX package identity** — an *unpackaged* exe (swift-pwa's
> default Windows artifact) gets `CapabilityMissing` / `E_ACCESSDENIED`, so you
> must ship Phi Silica from a **`--package-format msix`** build. They are also a
> **Limited Access Feature**: generation needs a Microsoft-issued unlock token
> for `com.microsoft.windows.ai.languagemodel` (per package family name, from
> the [LAF Access Token Request Form](https://learn.microsoft.com/windows/ai/apis/phi-silica)),
> passed via `PhiSilicaBackend(unlockToken:)` — the backend calls
> `LimitedAccessFeatures.TryUnlockFeature` (attestation auto-built from the
> running package's identity). AMD GPUs are "coming soon" upstream; today this
> is NPU (Copilot+) / NVIDIA-RTX only. See
> [docs/windows-setup.md](windows-setup.md#5-on-device-ai-phi-silica).

The prebuilt binaries are built from a pinned llama.cpp commit — the Apple
xcframework by
[`Scripts/build-llama-xcframework.sh`](../Scripts/build-llama-xcframework.sh),
the Linux static lib by
[`Scripts/build-llama-linux.sh`](../Scripts/build-llama-linux.sh), and the
Windows static lib by
[`Scripts/build-llama-windows.ps1`](../Scripts/build-llama-windows.ps1) (all the
same pinned commit; off Apple the GPU backend is swapped Metal → Vulkan), each
published to its own stable release by a `workflow_dispatch` workflow. We
package CMake's output rather
than vendoring ggml source because the source is 135+ per-arch model files
plus a shader-embed step and per-file SIMD flags SwiftPM can't express — and
`unsafeFlags` would poison dependency resolution for every adopter.

### Available backend: LaMa inpainting (image editing)

`SwiftPWAImageEdit` ships `LaMaBackend` — the first backend for the
**editing** side of `ai.generateImage` (an `image` + `mask` → the masked
region reconstructed; see the [contract above](#image-generation--editing-aigenerateimage)).
It reports `imageEditing: true` / `imageGeneration: false`, so `ai.generate`
(text) throws unsupported; it only edits images. It pairs directly with
[`ai.vision.*` segmentation](javascript-api.md#aivision--promptable-on-device-image-segmentation):
a SAM mask, decoded to a white-on-black PNG, is exactly the `mask` it
consumes — "tap to erase".

```swift
import SwiftPWAImageEdit

runtime.run { ctx in
    // Bundled / bring-your-own weights:
    ctx.use(AIPlugin(LaMaBackend(modelPath: myBigLamaONNXPath)))
    // …or the downloadable tier (ai.ensureModel fetches + checksum-pins):
    ctx.use(AIPlugin(LaMaBackend(cacheDirectory: dataDir)))
}
```

It reuses the shared **ONNX Runtime tier** (`SwiftPWAONNX` — the same
`OrtModelSession` MobileSAM runs on, including the desktop **CUDA / DirectML
GPU** providers under [`ai.onnx_gpu`](../docs/windows-setup.md) with transparent
CPU fallback). Opt in exactly like segmentation — set `ai.local_onnx_runtime:
true` in `pwa.json` so the build links ONNX Runtime; no separate flag. The
graph contract + pre/post-processing are a configurable `LaMaModelSpec`
(defaulting to the big-lama fp32 export — dynamic `H×W`, `[0,1]` RGB image +
`[0,1]` binary mask, `[0,255]` output); point it at a different export by
adjusting the spec, not the plumbing.

> **Status:** the contract, the backend, the **Apple + desktop
> (Linux/Windows)** image codecs, and the published **`lama-vendor`** weights
> release are in; `LaMaBackend(cacheDirectory:)` fetches out of the box. The
> **real-weights pass is done on Apple/CPU and Linux/CPU** — the big-lama
> fp32 export runs end-to-end (a masked region inpaints away, unmasked pixels
> stay pristine), confirming `LaMaModelSpec.bigLama`. The **Android** codec
> (BitmapFactory decode + `Bitmap.compress` over the Kotlin RPC) is
> **device-verified on a Galaxy Tab S10+**, so inpainting runs on all five
> platforms. See
> [docs/proposals/image-generation-editing.md](proposals/image-generation-editing.md).

### Structured output: native vs. the shared fallback

`ai.generateJSON` must return schema-valid JSON *regardless of backend*,
so the guarantee lives in two layers:

1. **Native (preferred).** A backend whose runtime constrains decoding to
   a schema — Foundation Models guided generation, llama.cpp GBNF
   grammars, ONNX Runtime GenAI — overrides `generateJSON` and enforces
   the schema at decode time. It reports `structuredOutput: true`.
2. **Fallback (in Core, inherited by everyone else).** For backends that
   can only emit free text, the default `generateJSON`:
   injects the schema into the prompt → calls `generate` → extracts JSON
   from the reply (tolerating markdown fences and surrounding prose) →
   validates it → and on failure makes **one** repair attempt before
   throwing `E_AI_STRUCTURED_OUTPUT`.

   The fallback's validation is **shallow** — it confirms the reply parses
   as JSON and, for an object schema, that the declared `required` keys
   are present. It is not a full JSON Schema validator; a backend that
   needs strict conformance should constrain decoding natively.

## Backend roadmap

The plugin reports the chosen `backend` so apps can show provenance / make
routing decisions. Priority is **platform built-in → bundled/downloaded
small model → none** (the app supplies its own cloud tier on top).

**Text + vision:**

| Tier | Apple | Android | Windows | Linux |
| --- | --- | --- | --- | --- |
| 1 — platform built-in | **Foundation Models (`apple-foundation-models`) — shipped ✅** | **Gemini Nano / ML Kit GenAI (`gemini-nano`) — shipped ✅** | **Windows AI / Phi Silica (`phi-silica`) — implemented; needs MSIX + LAF token** | — |
| 2 — downloadable GGUF | **llama.cpp (`gemma-llamacpp`) — shipped ✅** / MLX-Swift (`gemma-mlx`) | MediaPipe LLM Inference (`gemma-mediapipe`) | ONNX Runtime GenAI (`gemma-onnx`) / **llama.cpp — shipped ✅ (x64 Vulkan + arm64 CPU)** | **llama.cpp (Vulkan) — shipped ✅** |
| 3 — none | `none` → `available:false` | | | |

llama.cpp (`gemma-llamacpp`) is the portable tier-2 path: **Apple (Metal),
Linux x86_64 (Vulkan), and Windows (x64 Vulkan + arm64 CPU) all shipped ✅**. The
Swift `LlamaBackend` is platform-agnostic — only the prebuilt binary differs per
platform (xcframework on Apple, static `libllama.a` on Linux, `llama.lib` on
Windows). On Windows arm64 it's CPU (the unpackaged, no-token fallback to Phi
Silica there); an Adreno GPU/Vulkan build path exists behind an experimental
opt-in but isn't shipped — the Adreno X1's Vulkan compute currently returns
incorrect output (upstream Qualcomm-driver / ggml-shader immaturity). See
[docs/windows-setup.md](windows-setup.md#4-optional--on-device-ai-llamacpp).

Vision input rides the same backends where the model is multimodal (e.g.
Gemini Nano's vision variants, a vision Gemma), gated by the `vision` flag.

**Text-to-image** (`imageGeneration`), as a separate set of backends:

| Apple | Android | Windows | Linux |
| --- | --- | --- | --- |
| Image Playground (`apple-image-playground`) / Stable Diffusion via MLX (`stable-diffusion-mlx`) | MediaPipe Image Generation (`stable-diffusion-mediapipe`) | Stable Diffusion via ONNX Runtime (`stable-diffusion-onnx`) | (ONNX / llama.cpp-adjacent) |

**Audio** — input (`audioInput`: ASR / phoneme evaluation) and output
(`audioGeneration`: TTS). On Apple, `Speech` / `AVSpeechSynthesizer`
(`apple-speech`) for the system path, Whisper-via-MLX (`whisper-mlx`) and a
TTS model (`tts-mlx`) for the portable path; equivalents on the other OSes.

### Not in this contract (separate roadmap items)

- **Live duplex audio streaming.** Continuous mic → incremental results
  within an open session is not expressible on today's bridge (no
  client→server push mid-subscription). It needs a bridge-level
  bidirectional session primitive — broader than AI, so it's tracked
  separately rather than designed speculatively here. Interim:
  `MediaRecorder` timeslices → repeated `ai.generateJSON`.
- **Native audio capture / playback (platform audio).** The `ai.*`
  contract only moves audio *bytes*; the page already gets recordings from
  the WebView's `MediaRecorder`, so discrete audio I/O needs no native
  audio plumbing. Lower-latency native capture / playback / device routing
  is a separate platform-plugin effort on the project roadmap.

Like the zip backends (`ArchiveExtractor` in Core, `ZIPExtractor` in the
optional `SwiftPWAArchive` target), each real backend lives in its own
optional target with a platform-conditional dependency and is injected by
the app — Core itself never takes on a model-runtime dependency.

Tier-1 built-ins are gated on OS availability (e.g. Apple Foundation
Models requires the model to be present and enabled); when unavailable a
backend reports `available:false` and the app falls back. Tier 2 adds the
`ai.ensureModel` download/cache machinery and the Gemma licensing
question (likely download-on-demand to keep the app binary small).
