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

## Swapping the model

Edit the `ModelSpec` in
[Sources/CritterFacts/CritterFacts.swift](Sources/CritterFacts/CritterFacts.swift):
point `url` / `sha256` / `fileName` at any GGUF (a bigger model just means a
longer first-run download). Or use the `LlamaBackend(modelPath:)` initializer to
load a model already on disk.
