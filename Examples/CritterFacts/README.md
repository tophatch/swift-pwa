# CritterFacts

A tiny swift-pwa demo of the **`ai.*` on-device AI plugin**. Tap a button and a
local model streams back a one-sentence fun fact about a randomly chosen
critter — no network after the model is ready. The same backend-agnostic page
runs on two tiers of backend:

- **Apple / Linux / Windows** → the portable **llama.cpp backend**
  (`SwiftPWALlama`), Metal on Apple and Vulkan on Linux/Windows.
- **Android** → the platform built-in **Gemini Nano** (`GeminiNanoBackend`, via
  ML Kit GenAI / AICore) — no app-shipped weights.

It exercises the whole on-device AI path end to end:

- **`ai.local_llama: true`** / **`ai.gemini_nano: true`** in [pwa.json](pwa.json)
  — the per-platform switches (the CLI applies the right one per target).
- **`ai.ensureModel`** — on llama, downloads a tiny (~400 MB, Apache-2.0)
  [Qwen2.5-0.5B-Instruct](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF)
  GGUF on first run (resumable + checksum-pinned via `ModelDownloader`); on
  Android, AICore fetches Gemini Nano on demand. The page shows progress.
- **`ai.generateStream`** — tokens stream into the UI as they're produced.

The llama model runs **Metal-accelerated on Apple** and **Vulkan-accelerated on
Linux and Windows** (GPU if present, CPU fallback otherwise); Gemini Nano runs
on the device's NPU/accelerator via AICore — same page, same `ai.*` calls.

It also carries three on-device image demos: **segmentation** (`ai.vision.*`,
`MobileSAMBackend`), **tap-to-erase inpainting** (`ai.generateImage` with an
`image` + `mask`, `LaMaBackend`) that chains the two, and **prompt-to-image**
(`ai.generateImage` with a bare `prompt`, `StableDiffusionBackend`) — see
[On-device segmentation](#on-device-segmentation-aivision),
[On-device erase](#on-device-erase-aigenerateimage-inpainting), and
[On-device image generation](#on-device-image-generation-aigenerateimage-text-image)
below.

## Build & run

The backend is opt-in, so build through the CLI (which sets `SWIFT_PWA_LLAMA`
from `ai.local_llama`) rather than a bare `swift build`.

### macOS

```bash
# from a swift-pwa checkout
swift build --product swift-pwa
cd Examples/CritterFacts
../../.build/debug/swift-pwa build --target macos
open "build/CritterFacts.app"
```

Or for a quick dev loop, set the flag yourself and `swift run`:

```bash
cd Examples/CritterFacts
SWIFT_PWA_LLAMA=1 swift run
```

### Linux (Vulkan)

Needs the Vulkan loader's dev package to link, and a Vulkan driver/ICD at
runtime for GPU acceleration (CPU otherwise). See
[docs/linux-setup.md §7](../../docs/linux-setup.md#7-optional--on-device-ai-llamacpp-vulkan).

```bash
sudo apt-get install -y libvulkan-dev
cd Examples/CritterFacts
../../.build/debug/swift-pwa build --target linux
./build/CritterFacts-x86_64.AppImage
```

`swift-pwa build` downloads the prebuilt `libllama.a` automatically. To use a
locally built lib instead (e.g. while hacking on swift-pwa), build it with
`Scripts/build-llama-linux.sh` and export
`SWIFT_PWA_LLAMA_LINUX_LIB_DIR=<repo>/Vendor/llama-linux`.

### Windows (Vulkan)

Build from a Visual Studio Developer PowerShell. Needs the
[Vulkan SDK](https://vulkan.lunarg.com/sdk/home#windows) to link
(`vulkan-1.lib`) and a Vulkan driver/ICD at runtime for GPU acceleration (CPU
otherwise). See
[docs/windows-setup.md §4](../../docs/windows-setup.md#4-optional--on-device-ai-llamacpp-vulkan).

```powershell
cd Examples\CritterFacts
..\..\.build\debug\swift-pwa.exe build --target windows
.\build\CritterFacts\CritterFacts.exe
```

`swift-pwa build` downloads the prebuilt `llama.lib` automatically. To use a
locally built lib instead, build it with `Scripts\build-llama-windows.ps1` and
export `$env:SWIFT_PWA_LLAMA_WINDOWS_LIB_DIR='<repo>\Vendor\llama-windows'`.

### Android (Gemini Nano)

On Android the app uses **Gemini Nano** (the `ai.gemini_nano: true` flag),
not llama — there are no weights to ship. Needs an AICore-capable device
(Pixel 9/10, Galaxy S25/S26, Galaxy Z Fold7, …); AICore downloads the model on
demand. Build + bundle the same way as any Android target (see
[docs/android-setup.md](../../docs/android-setup.md)):

```bash
cd Examples/CritterFacts
swift run --package-path ../.. swift-pwa build \
  --target android --cross-compile-android --android-abis arm64-v8a
cd build/CritterFacts-android && ./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## On-device segmentation (`ai.vision.*`)

Alongside the fact generator, this app wires **`MobileSAMBackend`**
(`SwiftPWASegmentation`) — promptable on-device image segmentation, verified
end-to-end on both Apple and a real Android device (Galaxy Z Fold7) against
a real photo. The **"🐱 Tap-to-segment a kitten"** button on the main page
opens [web/segment.html](Sources/CritterFacts/web/segment.html): a full-screen
canvas showing a photo of kittens where tapping one draws a mask over it (tap
elsewhere to reselect) — the canonical SAM tap-to-segment interaction, running
entirely on-device. It's enabled via **`ai.local_onnx_runtime: true`** in
[pwa.json](pwa.json), the same pattern as `ai.local_llama` — `swift-pwa
build` sets `SWIFT_PWA_ONNXRUNTIME=1` for you (Apple + Android; on Android it
also resolves + stages `libonnxruntime.so` per ABI automatically).

The three MobileSAM ONNX weight files (~60 MB, Apache-2.0, sourced from
[`Acly/MobileSAM`](https://huggingface.co/Acly/MobileSAM) — see
[docs/proposals/segmentation-plugin.md](../../docs/proposals/segmentation-plugin.md))
are **not** shipped with the app. It uses the **downloadable tier**:
`MobileSAMBackend(cacheDirectory:)` fetches them on first use from the
`mobilesam-vendor` release (resumable + checksum-pinned via the same
`ModelDownloader` the llama GGUF uses), into the app's data directory. Same
wiring on Apple and Android — and on Android it sidesteps the "an APK asset
isn't a file ONNX Runtime can open" problem for free, since the downloader
writes straight to a real path.

**Build**: same as above — no extra flag needed, `pwa.json` already turns it
on. For a quick `swift build`/`swift run` dev loop that bypasses the CLI, set
the env var directly instead:

```bash
cd Examples/CritterFacts
SWIFT_PWA_ONNXRUNTIME=1 swift build
```

Drive the download once before your first `ai.vision.openSession`.
[web/mobilesam.js](Sources/CritterFacts/web/mobilesam.js) wraps
`ai.vision.ensureModel` as `window.ensureSegmentationModel(onProgress)`:

```js
await ensureSegmentationModel((done, total) => console.log(`${done}/${total} bytes`));
const { sessionId, width, height } = await __SWIFT_PWA__.invoke('ai.vision.openSession', {
    image: { path: /* a real on-device path, or use dataBase64 */ }
});
const { masks } = await __SWIFT_PWA__.invoke('ai.vision.segment', {
    sessionId, points: [{ x: width / 2, y: height / 2, label: 1 }], multimask: true,
});
```

Nothing app-specific is needed to link it: Apple's vendored ONNX Runtime
xcframework embeds protobuf (which needs `libc++`), but `SwiftPWASegmentation`
declares that link itself, and the Android `libonnxruntime.so` staging + the
per-ABI `.so` fetch are handled for you by `swift-pwa build`. So this app's
`Package.swift` just adds the `SwiftPWASegmentation` product — no extra
`linkerSettings`.

## On-device erase (`ai.generateImage` inpainting)

The **"🪄 Tap-to-erase a kitten"** button
([web/erase.html](Sources/CritterFacts/web/erase.html)) chains segmentation into
**LaMa inpainting** (`SwiftPWAImageEdit`'s `LaMaBackend`): tap a kitten →
`ai.vision.segment` produces a mask → the page paints it into a white-on-black
PNG → `ai.generateImage({ image, mask })` reconstructs the region, erasing the
kitten. The whole pipeline runs on-device (Apple + Linux/Windows today; the
Android image codec is a follow-up).

Because `AIPlugin` takes **one** backend but this app wants both text (facts)
*and* image editing on the `ai.*` surface, it composes them behind a tiny
[`CompositeAIBackend`](Sources/CritterFacts/CompositeAIBackend.swift) — text
requests go to the platform/llama backend, `generateImage` to LaMa, and
`ai.ensureModel({ model: "inpaint" })` routes the big-lama download. That's the
intended "an adopter gives one `ai.*` surface more than one purpose" pattern:
the backends we ship are examples, not a fixed menu. Enabled by the same
**`ai.local_onnx_runtime: true`** flag as segmentation (the big-lama ONNX,
~200 MB, is fetched on first use from the `lama-vendor` release).

## On-device image generation (`ai.generateImage` text→image)

The **"🎨 Generate an image from a prompt"** button
([web/generate.html](Sources/CritterFacts/web/generate.html)) runs
**Stable Diffusion** (`SwiftPWAStableDiffusion`'s `StableDiffusionBackend`)
fully on-device: type a prompt → `ai.generateImage({ prompt })` → a PNG. The
pipeline is **LCM_Dreamshaper** (CLIP tokenizer + text encoder + UNet + VAE
decoder + LCM scheduler), a 4-step Latent Consistency Model — quick on a GPU, a
few seconds on CPU. We use it (rather than SD-Turbo) because it's **OpenRAIL-M /
commercially usable**; SD-Turbo is non-commercial. Both ship — swap the
`StableDiffusionModelSpec`/`Source` to switch.

It joins LaMa on the same [`CompositeAIBackend`](Sources/CritterFacts/CompositeAIBackend.swift):
`ai.generateImage` is routed by whether the request carries a source `image` —
**present ⇒ inpaint (LaMa), absent ⇒ text→image (SD)** — so one `ai.*` surface
serves facts, erase, *and* generation. `ai.ensureModel({ model: "generate" })`
routes the SD download. Enabled by the same **`ai.local_onnx_runtime: true`**
flag; the fp16 LCM_Dreamshaper weights (~2.0 GB) are fetched on first use
from the `sd-vendor` release.

## Swapping the model

Edit the `ModelSpec` in
[Sources/CritterFacts/CritterFacts.swift](Sources/CritterFacts/CritterFacts.swift):
point `url` / `sha256` / `fileName` at any GGUF (a bigger model just means a
longer first-run download). Or use the `LlamaBackend(modelPath:)` initializer to
load a model already on disk.
