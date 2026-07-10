# Proposal: desktop GPU execution providers for ONNX Runtime (`ai.vision.*`)

> **Status: proposed, targeting v0.8.2.** The `ai.vision.*` segmentation
> tier reached full cross-platform parity in
> [v0.8.1](../../CHANGELOG.md), but the Linux x86_64 + Windows x64 desktop
> backends run ONNX Runtime on the **CPU**. This proposal is the one
> remaining vision fast-follow: move desktop inference onto the **GPU**.
> No code has landed yet — this documents the design and, importantly,
> the research finding that shaped it (there is **no** cross-vendor
> prebuilt GPU layer for ONNX Runtime desktop, unlike llama.cpp's
> Vulkan). See **Maintainer evaluation / decision** at the bottom for the
> scoping calls already made.

## Motivation

MobileSAM's encoder is the expensive step (a ViT forward pass over a
1024² image). On a desktop CPU it dominates `openSession` latency, and
it is run once per image — but **automatic mask generation**
(`ai.vision.segmentAll`, shipped in 0.8.1) then runs a
`pointsPerSide²` grid of decoder passes against that embedding, so a
slow encode plus dozens of decodes makes "segment everything" sluggish
on the exact desktop hardware most likely to have a capable GPU sitting
idle. `ai.vision.benchmark`'s `deviceClass` bucket already exists to let
apps adapt; a GPU path is how a `low`/`mid` desktop becomes `high`.

Apple (CoreML/Metal via the OS) and mobile (see *Out of scope* below)
are separate stories. This proposal is **desktop only** — Linux x86_64
and Windows x64, the two backends that ship as CPU-only today.

## The research finding — no Vulkan-equivalent for ONNX Runtime

llama.cpp gave us **one artifact for all GPU vendors** on desktop via
**Vulkan** (`v0.7.3`: NVIDIA / AMD / Intel from a single build). The
obvious question was whether ONNX Runtime offers the same. It does not:

- **Vulkan EP** — an open [feature request
  (microsoft/onnxruntime#21917)](https://github.com/microsoft/onnxruntime/issues/21917),
  never shipped.
- **WebGPU EP** — conceptually *is* "the Vulkan layer" (a low-level
  abstraction over D3D12 / Vulkan / Metal; WebGPU-native on Dawn uses
  Vulkan on Linux). **But** the official [execution-provider
  matrix](https://onnxruntime.ai/docs/execution-providers/) lists it as
  **web / WASM only**. The *native* C/C++ desktop WebGPU EP is still a
  [feature request (#22077)](https://github.com/microsoft/onnxruntime/issues/22077),
  absent from every prebuilt desktop binary. Using it would mean
  **building ONNX Runtime from source with Dawn** — a wholesale
  departure from this project's "vendor Microsoft's prebuilt libs"
  packaging model, at preview maturity.

**Conclusion:** ONNX Runtime desktop GPU means **vendor-specific**
execution providers. What that leaves, and which are prebuilt +
verifiable on our hardware:

| Platform | Provider | Cross-vendor? | Prebuilt? | External runtime deps | Verifiable here |
|---|---|---|---|---|---|
| **Windows** | **DirectML** | ✅ all DX12 GPUs (NVIDIA/AMD/Intel) | ✅ | none (DirectML is in-box on Win10+) | ✅ Radeon 780M (bmsfmv3) |
| **Linux** | **CUDA** | ❌ NVIDIA only | ✅ | CUDA runtime + cuDNN (~hundreds of MB) | ✅ NVIDIA e-GPU on both Linux boxes |
| Linux | ROCm / MIGraphX | ❌ AMD only | partial | ROCm stack | ❌ (Radeon **iGPUs** aren't ROCm targets) |
| Linux | OpenVINO | ❌ Intel only | ✅ | OpenVINO runtime | — (out of scope) |

The asymmetry is the headline: **Windows gets a genuinely cross-vendor
GPU path (DirectML); Linux does not.** On Linux the only prebuilt,
production GPU EP is CUDA — NVIDIA-only. The AMD Radeon **iGPUs** in the
Linux verify boxes cannot drive an ORT GPU EP at all (ROCm doesn't
target Radeon integrated graphics, and there is no native Vulkan/WebGPU
EP), so on Linux the AMD parts stay on CPU. AMD-GPU acceleration is
still *proven* in this proposal — but on **Windows**, through DirectML
on the Radeon 780M.

## Proposed design

### Runtime behavior — automatic, no per-user config

The consumer-facing contract is **auto-detect with CPU fallback**:

1. At `CreateSession`, append the platform GPU EP (DirectML on Windows,
   CUDA on Linux) *before* the default CPU EP.
2. If the GPU EP fails to initialize — no capable GPU, no driver, or (on
   Linux) no CUDA/cuDNN runtime present — ONNX Runtime falls through to
   the CPU EP. We catch the append failure, **log once**, and continue
   on CPU. Inference is never broken by the absence of a GPU.
3. `ai.vision.info` surfaces the **active provider** (`"directml"` /
   `"cuda"` / `"cpu"`) so an app (or `benchmark`) can report it.

No `getUserMedia`-style permission, no user toggle. An app that opts in
(below) gets the GPU when the machine can provide one and the CPU
otherwise, transparently — the right default for shipped consumer apps.

### Build-time opt-in — keep CPU-only apps lean

The GPU-capable ORT builds are larger (and on Linux imply a CUDA
runtime expectation on the target). So pulling them is a **build-time
opt-in**, keeping the default `ai.local_onnx_runtime` on the lean CPU
artifact. The flag is a sibling boolean — **`ai.onnx_gpu: true`** —
layered on `ai.local_onnx_runtime` (chosen for simplicity over a
`ai.local_onnx_runtime: "gpu"` mode). It only chooses *which artifact
ships*; the auto-detect runtime behavior above is unconditional once the
GPU-capable artifact is present. Desktop-only, like its CPU counterpart
— ignored (with a warning) on macOS/iOS/Android.

### Packaging — reuse the 0.8.1 desktop infrastructure

Everything the CPU desktop backend built in
[#59](https://github.com/tophatch/swift-pwa/pull/59) is reused, pointed
at the GPU builds:

- **Resolvers** — `OnnxRuntime{Linux,Windows}Artifact` gain a GPU
  variant (env override → local `Vendor/` → checksum-pinned download
  from new `onnxruntime-vendor-{linux,windows}-gpu` release channels).
- **Gate** — `applyLocalOnnxRuntimeGate` selects the GPU artifact dir
  for `LIBRARY_PATH` (Linux) / `LIB` (Windows) when the flag is set.
- **Bundler staging:**
  - **Windows DirectML** — stage `onnxruntime.dll` (the DirectML build,
    which retains the CPU EP for fallback) **plus `DirectML.dll`** next
    to the `.exe`, including `--single-file`. No CUDA-style external
    dependency — DirectML ships in-box on Windows 10+.
  - **Linux CUDA** — stage the GPU `libonnxruntime.so.1` **plus the
    provider libs** (`libonnxruntime_providers_shared.so`,
    `libonnxruntime_providers_cuda.so`) into the AppImage
    (`linuxdeploy --library`, SONAME-correct, same as the CPU `.so`).
    The CUDA runtime + cuDNN are **not bundled** — they are expected on
    the target; a missing/mismatched CUDA runtime surfaces as the GPU EP
    failing to load, which the auto-fallback turns into a CPU run + a
    one-line log (and `benchmark`/`info` reporting `cpu`).

### Concrete artifact sources (verified against the v1.27.0 release)

- **Linux CUDA** — `onnxruntime-linux-x64-gpu_cuda12-1.27.0.tgz`
  (Microsoft's GitHub release; the naming is now split by CUDA major —
  we take **CUDA 12**, vastly the broader install base over CUDA 13).
  **ORT 1.27.0 — matches our committed desktop headers**, so this reuses
  the existing `ONNXRuntimeDesktop` module directly. ~228 MB (vs. the
  8 MB CPU tarball — it carries the CUDA + TensorRT providers).
- **Windows DirectML** — the `Microsoft.ML.OnnxRuntime.DirectML` **NuGet
  package** (the DirectML build is *not* a GitHub-release asset; the
  release `-gpu_cuda12/13-` Windows zips are CUDA, which would be
  NVIDIA-only and can't be verified on our AMD Radeon Windows box). Its
  latest version is **1.24.4**, which **lags** our 1.27.0 desktop
  headers — a 1.27 header requests a newer `ORT_API_VERSION` than a
  1.24.4 runtime provides (`OrtGetApiBase()->GetApi()` returns null →
  crash). So DirectML gets its **own pinned 1.24.4 header set + module**
  (`ONNXRuntimeDirectML`, including `dml_provider_factory.h` for the
  `OrtSessionOptionsAppendExecutionProvider_DML` C function, which is not
  in the CPU/CUDA header set), kept separate from `ONNXRuntimeDesktop`
  so each artifact's headers match its runtime's API version. DirectML
  stays the Windows choice regardless of the lag: it is the only
  cross-vendor path *and* the only one verifiable on our hardware.

### The CUDA/cuDNN version-pinning risk (Linux)

ONNX Runtime pins the CUDA/cuDNN **major** versions it was built
against (e.g. ORT 1.27 → a specific CUDA 12.x + cuDNN 9.x). A user with
a mismatched CUDA runtime gets a silent CPU fallback, not an error they
can act on. Mitigation: document the exact required CUDA/cuDNN versions
in `docs/linux-setup.md`, and have the "GPU EP failed to load" log line
name the versions ORT expects. This brittleness is a large part of why
Linux GPU is NVIDIA/CUDA-only and gated behind an explicit opt-in
rather than on by default.

## Verification plan

Same throwaway-executable + real-cat-photo harness as the 0.8.1 desktop
work — but the acceptance bar is **the GPU EP actually engaged**, not a
silent CPU fallback:

- **Windows DirectML** on `bmsfmv3` (AMD Radeon 780M, DX12) — confirm
  `ai.vision.info` reports `directml` and a `benchmark` encode-time drop
  vs. the CPU build.
- **Linux CUDA** on the NVIDIA e-GPU box — confirm `info` reports `cuda`
  and a benchmark delta; the AMD iGPU on the same box exercises the
  **CPU fallback** path (GPU EP requested, none usable → CPU).
- Cross-check byte-identical mask output GPU-vs-CPU on both (the EP
  changes speed, not results, modulo float ordering — assert IoU ≈ 1.0
  against the CPU baseline rather than exact bytes).

## Out of scope (related future work)

- **Mobile / Apple acceleration.** `MobileSAMBackend` on Apple + Android
  also runs the ORT **CPU** EP today. The analogues are the **CoreML
  EP** (Apple, Metal/ANE) and **NNAPI/QNN EPs** (Android) — separate
  work with their own packaging, not part of this desktop-GPU item.
- **Linux AMD/Intel GPU** (ROCm / OpenVINO) — deferred; no verifiable
  Radeon-iGPU path exists in prebuilt ORT, and discrete-AMD/Intel demand
  is unproven. Revisit if a native WebGPU/Vulkan EP ships in prebuilt
  desktop binaries (it would collapse this whole matrix into one
  cross-vendor artifact per platform, the llama story).
- **TensorRT** (NVIDIA, faster than CUDA but heavier still) — a possible
  later Linux/Windows-NVIDIA tier once CUDA is proven.

## Maintainer evaluation / decision

Scoping calls made with the maintainer before writing this:

- **CUDA runtime is required, not bundled** — fail (well, fall back)
  clearly rather than ship hundreds of MB of CUDA/cuDNN.
- **Auto-detect at runtime**, CPU fallback, no user config — the right
  consumer default; the only opt-in is the app-developer build flag that
  chooses the GPU-capable artifact.
- **Hardware reality drives the platform split** — Windows DirectML is
  the cross-vendor win (verified on AMD Radeon); Linux is CUDA-only, now
  verifiable because both Linux boxes have an NVIDIA e-GPU (their AMD
  Radeon iGPUs can only exercise the CPU-fallback path).
- **No Vulkan/WebGPU shortcut exists** for ORT desktop today — confirmed
  by research, not assumed; if that changes upstream it supersedes the
  vendor-specific approach here.
