# On-device AI (text and images)

**Who this is for:** you're wrapping a web app with [swift-pwa](https://github.com/tophatch/swift-pwa) and you want it to *think* — generate text, answer questions, produce structured JSON, or make images — **on the user's device**, with no server, no API key, and no per-token bill. This is the thing that's a DIY sidecar in Electron/Tauri and a first-class, cross-platform feature here.

Your page talks to one small JS API — `ai.*` — and *where* the work runs (a model the OS ships, a small model we bundle, a model you bring, or your own cloud as a fallback) is a Swift-side decision your web code never has to encode. Swap the engine underneath; the page doesn't change.

This guide has four parts, easiest first:

1. **[Use a backend we package](#part-1--use-a-backend-we-package)** — flip one flag, add one line of Swift, call `ai.*`. ~10 minutes.
2. **[Bring a model we don't package](#part-2--bring-a-model-we-dont-package)** — point an existing backend at your own weights (a different GGUF, your own ONNX pipeline).
3. **[Write your own backend](#part-3--write-your-own-backend)** — conform to one Swift protocol (e.g. to proxy your own cloud, or wrap an engine we don't ship).
4. **[Custom styles with LoRA](#part-4--custom-styles-with-lora)** — the how-and-why of getting a LoRA fine-tune running on-device.

> Needs swift-pwa **0.8.5 or newer** (text has shipped since 0.7.1; on-device image generation since 0.8.5). The `ai.*` API is frozen — a page written against it lights up on whatever backend you inject, on macOS, iOS, Linux, Windows, and Android.
>
> For the complete reference behind this guide, see [the `ai.*` plugin reference](../ai-plugin.md). This tutorial is the hands-on path.

---

## The big picture

```
Your web app (JavaScript)                     The native shell (Swift)
  ┌─ ai.info  ──────────────────────────▶  "is on-device AI usable? what can it do?"
  │                                    ◀──  { available, backend, streaming, … }
  │
  │  (first run only)
  │  ai.ensureModel  ───────────────────▶  download the model to disk
  │                                    ◀──  progress… then "ready"   (resumable, checksummed)
  │
  │  ai.generate / ai.generateStream ───▶  ┌───────────────────────────────────┐
  │  ai.generateJSON                       │  ONE AIBackend, your choice:        │
  │  ai.generateImage               ◀──    │   • a model the OS ships            │
  │                                         │   • a small model we bundle         │
  └─────────────────────────────────────   │   • a model you bring               │
                                            │   • your own cloud (a fallback)     │
                                            └───────────────────────────────────┘
```

The page only ever calls `ai.*`. The **one** Swift decision is *which `AIBackend` you hand to `AIPlugin`*. That's the whole design.

---

## Part 1 — Use a backend we package

The fastest path. We ship real on-device engines; you turn one on and wire it in.

### Step 1 — pick a backend (a `pwa.json` flag)

Add a flag to your `pwa.json`. `swift-pwa build` reads it and links the right engine (and, where needed, stages native libraries into the app bundle for you).

| `pwa.json` flag | What you get | Swift module / backend | Platforms |
|---|---|---|---|
| `ai.local_llama: true` | **llama.cpp** — any GGUF chat/instruct model. Text + streaming + JSON. GPU-accelerated (Metal on Apple, Vulkan on Linux/Windows). **The easiest place to start** — one flag, works everywhere. | `SwiftPWALlama` · `LlamaBackend` | macOS, iOS, Linux, Windows |
| `ai.gemini_nano: true` | **Android Gemini Nano** — the OS's built-in model via ML Kit / AICore. No weights to ship; the OS downloads on demand. | (bundled) · `GeminiNanoBackend` | Android |
| `ai.phi_silica: true` | **Windows Phi Silica** — the Copilot+ NPU model via the Windows App SDK. | `SwiftPWAPhiSilica` · `PhiSilicaBackend` | Windows (MSIX build) |
| `ai.local_onnx_runtime: true` | **ONNX Runtime tier** — image *segmentation* (`MobileSAMBackend`), image *editing*/inpaint (`LaMaBackend`), and text→image *generation* (`StableDiffusionBackend`, SD-Turbo). | `SwiftPWASegmentation` / `SwiftPWAImageEdit` / `SwiftPWAStableDiffusion` | macOS, iOS, Linux, Windows, Android |
| `ai.onnx_gpu: true` | Optional GPU acceleration for the ONNX tier (Windows DirectML / Linux CUDA, auto-detect + CPU fallback). Layer on top of `ai.local_onnx_runtime`. | — | Linux, Windows desktop |

On **Apple** there's also **Apple Foundation Models** (`SwiftPWAFoundationModels` · `FoundationModelsBackend`) — the OS model, no download, native schema-constrained JSON. It needs no flag; you construct it directly (Step 2).

> The one-liner for this tutorial: **start with `ai.local_llama`.** It's the most portable and the least fussy, and everything you learn transfers to the other backends.

```jsonc
// pwa.json
{
  "id": "com.example.myapp",
  "name": "My App",
  "web": { "directory": "Sources/MyApp/web", "entry": "index.html" },
  "ai": {
    "local_llama": true
  }
}
```

### Step 2 — wire the backend (a few lines of Swift, once)

In the generated `Sources/<YourApp>/App.swift`, inside the `configure` closure, construct the backend and hand it to `AIPlugin`. `AIPlugin` is opt-in (like `fs.*` / `dialog.*`) — nothing is auto-installed.

```swift
import SwiftPWA
import SwiftPWAModelStore   // ModelSpec (the downloadable-model descriptor)
#if canImport(SwiftPWALlama)
    import SwiftPWALlama
#endif

@MainActor
func configure(_ ctx: any AppContext) throws {
    #if canImport(SwiftPWALlama)
        // A small, permissively-licensed instruct model. It's *downloadable*:
        // the page calls ai.ensureModel once and we fetch it (resumable,
        // checksum-verified) into the app's data directory. Runs offline after.
        let model = ModelSpec(
            url: URL(string:
                "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/"
                + "resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf")!,
            sha256: "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db",
            fileName: "qwen2.5-0.5b-instruct-q4_k_m.gguf"
        )
        let modelsDir = ctx.dataDirectory().appendingPathComponent("models", isDirectory: true)
        ctx.use(AIPlugin(LlamaBackend(model: model, cacheDirectory: modelsDir)))
    #endif

    _ = try ctx.createWindow(WindowConfig(
        title: "My App",
        size: Size(width: 800, height: 600),
        content: .bundled(directory: locateWebRoot())
    ))
}
```

The `#if canImport(SwiftPWALlama)` guard means the app still builds and runs *without* the flag — you just get a shell with no AI, instead of a compile error. (This is the same pattern the [`CritterFacts` example](../../Examples/CritterFacts) uses.)

### Step 3 — call it from JavaScript

Now the whole thing is available in the page. There's no `ai`-specific JS sugar — it's the standard `invoke` / `subscribe`.

```js
const bridge = window.__SWIFT_PWA__;

// 1. Probe once at startup and route on `available`.
const info = await bridge.invoke("ai.info", {});
// → { available, backend, model?, streaming, structuredOutput,
//     vision, imageGeneration, audioInput, audioGeneration, voiceCloning }
if (!info.available) {
    // No on-device backend in this build — fall back to your own (e.g. cloud) tier.
}

// 2. First run only: download the model, with progress. (Cache hit is instant after.)
async function ensureModel() {
    return new Promise((resolve, reject) => {
        const unsub = bridge.subscribe("ai.ensureModel", {}, (e) => {
            if (e.type === "progress" && e.totalBytes) {
                showProgress(e.bytesDone / e.totalBytes);      // 0…1
            } else if (e.type === "done") { unsub(); resolve(); }
            else if (e.type === "error") { unsub(); reject(new Error(e.message)); }
        });
    });
}

// 3. Generate. Streaming — `delta` tokens, then `done`.
await ensureModel();
let text = "";
await new Promise((resolve, reject) => {
    const unsub = bridge.subscribe("ai.generateStream", {
        system: "You are a helpful assistant. Answer in one sentence.",
        prompt: "Why is the sky blue?",
        maxTokens: 120, temperature: 0.7,
    }, (e) => {
        if (e.type === "delta") { text += e.text; render(text); }
        else if (e.type === "done") { unsub(); resolve(); }
        else if (e.type === "error") { unsub(); reject(new Error(e.message)); }
    });
});
```

For a one-shot answer use `ai.generate` (returns `{ text, backend }`); for a **parsed, schema-valid object** use `ai.generateJSON` with a JSON Schema (backends that can't constrain decoding natively fall back to prompt-and-validate — you still get a valid object):

```js
const obj = await bridge.invoke("ai.generateJSON", {
    prompt: "Extract the date and amount from: 'Paid $42 on 2026-03-01'",
    schema: { type: "object", required: ["date", "amount"],
              properties: { date: { type: "string" }, amount: { type: "number" } } },
});
// → { date: "2026-03-01", amount: 42 }
```

**Generating images** works the same way — turn on `ai.local_onnx_runtime`, wire `StableDiffusionBackend` (see [`CritterFacts`'s `configure`](../../Examples/CritterFacts/Sources/CritterFacts/CritterFacts.swift)), and from JS:

```js
const { images } = await bridge.invoke("ai.generateImage", {
    prompt: "a red panda astronaut, digital art",
});
imgEl.src = "data:" + images[0].mimeType + ";base64," + images[0].dataBase64;
```

That's the packaged path, start to finish.

---

## Part 2 — Bring a model we don't package

You're not limited to the exact models we ship. The two engines that load model *files* — llama.cpp (GGUF) and the ONNX tier — take your own.

### 2a. A different GGUF (llama.cpp)

This is a one-value change: point the `ModelSpec` at any GGUF on the web (or a bigger quant of the same model — a bigger file just means a longer first-run download). Grab the URL and SHA-256 from the model card:

```swift
let model = ModelSpec(
    url: URL(string: "https://huggingface.co/<org>/<repo>/resolve/main/<model>.gguf")!,
    sha256: "<sha256 of that file>",
    fileName: "<model>.gguf"
)
ctx.use(AIPlugin(LlamaBackend(model: model, cacheDirectory: modelsDir)))
```

Already have the file on disk (bundled with the app, or placed by your own installer)? Skip the download tier entirely:

```swift
ctx.use(AIPlugin(LlamaBackend(modelPath: "/path/to/model.gguf")))
```

### 2b. Your own ONNX pipeline (Stable Diffusion)

`StableDiffusionBackend` is configurable. To run *your* SD-family weights (a different checkpoint, or a LoRA-merged model — see [Part 4](#part-4--custom-styles-with-lora)), host the exported ONNX files and hand the backend a `StableDiffusionModelSource` pointing at them:

```swift
import SwiftPWAStableDiffusion

let mySource = StableDiffusionModelSource(
    textEncoder:     .init(url: url("text_encoder.onnx"), sha256: "…", fileName: "text_encoder.onnx", sizeBytes: 681_210_842),
    unet:            .init(url: url("unet.onnx"),          sha256: "…", fileName: "unet.onnx",          sizeBytes: 1_732_796_415),
    vaeDecoder:      .init(url: url("vae_decoder.onnx"),   sha256: "…", fileName: "vae_decoder.onnx",   sizeBytes: 99_093_852),
    tokenizerVocab:  .init(url: url("vocab.json"),         sha256: "…", fileName: "vocab.json",         sizeBytes: 1_059_962),
    tokenizerMerges: .init(url: url("merges.txt"),         sha256: "…", fileName: "merges.txt",         sizeBytes: 524_619)
)
let sd = StableDiffusionBackend(cacheDirectory: sdDir, source: mySource, spec: .sdTurboFp16)
```

The `spec` (a `StableDiffusionModelSpec`) describes the graph contract — tensor names, dtypes, the scheduler, VAE scaling. `.sdTurbo` (fp32) and `.sdTurboFp16` (fp16) are ready to use; a different architecture (e.g. an SD-1.5 checkpoint) is a matter of adjusting the spec's fields. If your model is fp16, use `.sdTurboFp16` — **the backend already handles the one Android-specific gotcha for fp16 ONNX** (it lowers the graph-optimization level so the Android runtime doesn't try to run a fused half-precision op it has no kernel for).

### Serving more than one purpose from one `ai.*`

`AIPlugin` takes **one** backend — but "one" can compose several. If you want text *and* image editing *and* text→image all on the same `ai.*` surface, write a tiny router that forwards each call to the right engine. The [`CompositeAIBackend` in `CritterFacts`](../../Examples/CritterFacts/Sources/CritterFacts/CompositeAIBackend.swift) is a worked example: it sends `ai.generate*` to a text backend, and routes `ai.generateImage` by whether the request carries a source `image` (present → inpaint/LaMa, absent → text→image/SD). That "the adopter composes purposes" pattern is exactly what the contract is designed for.

---

## Part 3 — Write your own backend

Want to wrap an engine we don't ship, or proxy your own cloud API as the fallback tier? Conform to one protocol: **`AIBackend`**. Only two methods are required — `info()` and `generate()` — everything else (streaming, JSON, images, audio) has a default, so you implement only what you support.

Here's a complete, minimal backend that proxies your own HTTP endpoint. Drop it in `Sources/<YourApp>/`:

```swift
import Foundation
import SwiftPWA   // AIBackend, AICapabilities, AIGenerateRequest/Result, AIError, AIBackendID

struct MyCloudBackend: AIBackend {
    // 1. Advertise what you can do. The capability flags gate the JS surface:
    //    a page routes on these (streaming, structuredOutput, imageGeneration, …).
    func info() async -> AICapabilities {
        AICapabilities(available: true, backend: "my-cloud", model: "my-model-v1", streaming: false)
    }

    // 2. The one primitive everything else is built on.
    func generate(_ request: AIGenerateRequest) async throws -> AIGenerateResult {
        var req = URLRequest(url: URL(string: "https://api.example.com/generate")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode([
            "system": request.system ?? "", "prompt": request.prompt,
        ])
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let reply = try JSONDecoder().decode([String: String].self, from: data)
            return AIGenerateResult(text: reply["text"] ?? "", backend: "my-cloud")
        } catch {
            throw AIError.generationFailed("\(error)")   // → a stable E_AI_GENERATION on the JS side
        }
    }
}
```

Wire it exactly like a packaged one: `ctx.use(AIPlugin(MyCloudBackend()))`. The page's `ai.generate` / `ai.generateStream` / `ai.generateJSON` all work immediately — streaming falls back to a single `delta`+`done`, and JSON falls back to the shared prompt-and-validate helper, both for free.

**To do better than the defaults, override the relevant method:**

- **Real token streaming** → override `generateStream(_:)` and `yield(.delta(token))` as tokens arrive, then `yield(.done)`. Set `streaming: true` in `info()`.
- **Native schema-constrained JSON** → override `generateJSON(_:)`. Set `structuredOutput: true`.
- **Images** → override `generateImage(_:)` (and `generateImageStream(_:)` for per-step progress). Set `imageGeneration: true` (text→image) and/or `imageEditing: true` (accepts a source `image`).
- **A downloadable model** → override `ensureModel(_:)` to stream download progress. `ModelDownloader` (from `SwiftPWAModelStore`) gives you resumable, checksum-pinned downloads — the same one the packaged backends use.

Because the capability flags in `info()` are what the page routes on, an honest `info()` is the contract: report only what you actually implement, and pages degrade gracefully everywhere else.

---

## Part 4 — Custom styles with LoRA

LoRAs are the community's favourite way to teach an image model a style, a character, or a concept — small `.safetensors` files you'd stack on a base model. On-device, there's one thing to understand up front:

> **You can't drop a LoRA file in at runtime with the ONNX backend.** A LoRA is a set of *weight deltas* meant to be applied to a model's layers. ONNX ships a **frozen compute graph** — there's no adapter slot to load a delta into at inference time. (This is a property of the ONNX format, not of swift-pwa.)

The fix is to **bake the LoRA into the weights ahead of time**, then export *that* to ONNX. You do this once, on a workstation; the result is a normal ONNX pipeline you host and point a `StableDiffusionModelSource` at ([Part 2b](#2b-your-own-onnx-pipeline-stable-diffusion)). The steps:

**1. Merge (fuse) the LoRA into the base model** with 🤗 diffusers:

```python
# merge_lora.py  (run on a workstation, in a venv with torch + diffusers + peft)
from diffusers import StableDiffusionPipeline
import torch

pipe = StableDiffusionPipeline.from_pretrained("stabilityai/sd-turbo", torch_dtype=torch.float16)
pipe.load_lora_weights("path/to/your-style.safetensors")
pipe.fuse_lora()                       # bakes the deltas into the base weights
pipe.unload_lora_weights()
pipe.save_pretrained("sd-turbo-mystyle")   # a normal (merged) checkpoint
```

**2. Export the merged checkpoint to ONNX** — the same export the [`Scripts/vendor-sd.sh`](../../Scripts/vendor-sd.sh) helper uses for the packaged weights:

```bash
optimum-cli export onnx --model sd-turbo-mystyle --dtype fp16 --device cpu sd-turbo-mystyle-onnx
```

**3. Host the five files and point a source at them** — the URLs + SHA-256s go into a `StableDiffusionModelSource` ([Part 2b](#2b-your-own-onnx-pipeline-stable-diffusion)). `Scripts/vendor-sd.sh checksums` prints the exact `sha256`/`sizeBytes` to paste in.

A few things worth knowing:

- **Speed:** the "few-step" trick that makes on-device SD viable is itself a LoRA — **LCM-LoRA**. Merging an LCM-LoRA (plus your style LoRA) into an SD-1.5 base gives you a 4-step model that's fast on a phone. swift-pwa ships this path: use `StableDiffusionModelSpec.lcmDreamshaper(Fp16)` (its scheduler is `.lcm`, and the backend feeds the guidance embedding automatically) with your LCM-merged ONNX export. `LCM_Dreamshaper_v7` is the ready-made example (`StableDiffusionModelSource.lcmDreamshaperFp16`, verified end-to-end).
- **One model per style:** because the LoRA is baked in, each merged export *is* a style. If you want several, export several and let the user pick which `StableDiffusionModelSource` to download.
- **Licensing:** the base model's license flows through to your merged export. SD-Turbo is **non-commercial** (Stability AI Community License); for a commercial app, merge onto an **OpenRAIL-M** base (e.g. an SD-1.5 + LCM-LoRA combination) instead. Check your LoRA's license too.

The end result is indistinguishable from a packaged model to your page: `ai.generateImage({ prompt })` returns your style, on-device, offline.

---

## Where to go next

- **[`ai.*` plugin reference](../ai-plugin.md)** — every command, every field, the `AIBackend` protocol in full, and a worked guide to writing a native (TTS) backend.
- **[`Examples/CritterFacts`](../../Examples/CritterFacts)** — a live app: streamed local-LLM fun facts, tap-to-segment, tap-to-erase (LaMa inpaint), and prompt-to-image (Stable Diffusion), all behind one composed `ai.*` surface.
- **[JavaScript API](../javascript-api.md)** and **[Swift API](../swift-api.md)** — the bridge and `AppContext` reference behind everything above.
- **Per-platform build setup** — the [`*-setup.md`](../) docs (each notes any AI-specific packaging, e.g. the MSIX build Phi Silica needs, or the ONNX GPU tier).
