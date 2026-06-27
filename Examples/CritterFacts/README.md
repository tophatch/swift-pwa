# CritterFacts

A tiny swift-pwa demo of the **on-device llama.cpp backend** (`SwiftPWALlama`).
Tap a button and a local LLM streams back a one-sentence fun fact about a
randomly chosen critter — no network after the one-time model download.

It exercises the whole on-device AI path end to end:

- **`ai.local_llama: true`** in [pwa.json](pwa.json) — the only switch needed.
- **`ai.ensureModel`** — downloads a tiny (~400 MB, Apache-2.0)
  [Qwen2.5-0.5B-Instruct](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF)
  GGUF on first run (resumable + checksum-pinned via `ModelDownloader`), then
  reuses it. The page shows a download progress bar.
- **`ai.generateStream`** — tokens stream into the UI as they're produced.

The model runs **Metal-accelerated on Apple** and **Vulkan-accelerated on
Linux** (GPU if present, CPU fallback otherwise) — same code, same flag.

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

## Swapping the model

Edit the `ModelSpec` in
[Sources/CritterFacts/CritterFacts.swift](Sources/CritterFacts/CritterFacts.swift):
point `url` / `sha256` / `fileName` at any GGUF (a bigger model just means a
longer first-run download). Or use the `LlamaBackend(modelPath:)` initializer to
load a model already on disk.
