# On-device AI plugin (`ai.*`)

`AIPlugin` puts LLM inference behind the bridge so the web layer stays
provider-agnostic: the page asks `ai.*` for text or schema-constrained
JSON, and *where* that runs — a platform built-in model, a bundled small
model, or (the app's own) cloud fallback — is a Swift-side decision the
page never has to encode.

It is an **opt-in plugin** (like `fs.*` / `dialog.*`), not auto-installed:
an app calls `ctx.use(AIPlugin(...))` and supplies the backend.

> **Status (0.7): the contract, not yet the inference.** This release
> ships the full JS contract, the `AIBackend` protocol, the shared
> structured-output fallback, and `NoneBackend` (which reports
> `available: false`). No on-device backend is wired yet — a page can
> integrate against the frozen contract today and light up unchanged when
> a real backend lands. The per-platform backends below are the roadmap.

## JS surface

All via the standard `invoke` / `subscribe` — there's no `ai`-specific JS
sugar.

```js
// Capability probe — cheap, call once at startup and route on `available`.
const info = await __SWIFT_PWA__.invoke('ai.info', {});
// → { available, backend, model?, streaming, structuredOutput,
//     vision, imageGeneration, audioInput, audioGeneration }
//   backend ∈ none | apple-foundation-models | gemini-nano | phi-silica
//           | gemma-mlx | gemma-mediapipe | gemma-onnx | gemma-llamacpp
//           | apple-image-playground | stable-diffusion-mlx
//           | apple-speech | whisper-mlx | tts-mlx | …
if (!info.available) {
    // fall back to your own (e.g. cloud) tier
}
// Capability flags gate the modalities:
//   vision          → image input honored      imageGeneration → text→image
//   audioInput      → audio input honored       audioGeneration → text→audio

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

### Image generation (text-to-image)

When `info.imageGeneration` is true, `ai.generateImage` turns a prompt into
one or more images. Supply an `outputDirectory` to have them **written to
disk** and get back file paths (bridge-efficient — multi-MB image bytes
don't cross as base64; mount the directory with `serveDirectory` to show
them); omit it to get base64 bytes inline (fine for a single small image).

```js
const { images, backend } = await __SWIFT_PWA__.invoke('ai.generateImage', {
    prompt: 'a watercolor fox', negativePrompt: 'blurry',
    width: 512, height: 512, steps: 20, seed: 42, count: 1,
    outputDirectory: dataDir + '/generated',   // omit for inline base64
});
// → images: [{ path?|dataBase64?, mimeType, seed }], backend

// Streaming — denoising-step progress with optional intermediate previews.
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
| `E_UNIMPLEMENTED` | a reserved command not yet implemented (see `ai.ensureModel`) |

### `ai.ensureModel` (reserved)

`subscribe('ai.ensureModel', { model? }, …)` is **reserved** for the
downloadable-model tier (capacity gating, resumable download, checksum
pinning, progress events). It exists now so the contract is stable, but
throws `E_UNIMPLEMENTED` until that tier ships.

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
  it for a text-to-image backend (then set `imageGeneration: true`).
- **`generateImageStream`** defaults to wrapping `generateImage` in a
  single `done`. Override it to report per-step denoising progress.
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
| 1 — platform built-in | Foundation Models (`apple-foundation-models`) | Gemini Nano / ML Kit GenAI (`gemini-nano`) | Windows AI / Phi Silica (`phi-silica`) | — |
| 2 — downloadable Gemma | MLX-Swift (`gemma-mlx`) | MediaPipe LLM Inference (`gemma-mediapipe`) | ONNX Runtime GenAI (`gemma-onnx`) | llama.cpp (`gemma-llamacpp`) |
| 3 — none | `none` → `available:false` | | | |

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
