# swift-pwa on Linux (GTK3 + WebKitGTK 4.1, or GTK4 + WebKitGTK 6.0)

Two parallel Linux backends, selected at build time via the
`SWIFT_PWA_GTK4` environment variable. Both go through the same
`SwiftPWAGTK` Swift module, so downstream code is identical:

| Backend | Build command                  | System dev packages                                                     | Tested distro          |
|---------|--------------------------------|-------------------------------------------------------------------------|------------------------|
| GTK3    | `swift build` (default)        | `libgtk-3-dev`, `libwebkit2gtk-4.1-dev`, `libayatana-appindicator3-dev` | Ubuntu 22.04 / 24.04   |
| GTK4    | `SWIFT_PWA_GTK4=1 swift build` | `libgtk-4-dev`, `libwebkitgtk-6.0-dev`                                  | Ubuntu 24.04+ / 26.04  |

Pick GTK3 if you're shipping to older distros (Ubuntu 22.04 LTS doesn't
have WebKitGTK 6.0 in apt without a PPA). Pick GTK4 for modern distros
and the long-term direction. JS↔Swift bridge round-trip is verified
end-to-end against `Examples/HelloPWA` on both.

## 1. Install Swift 6.0+

The recommended path is Swiftly, the official toolchain manager.
Per [swift.org/install/linux](https://www.swift.org/install/linux/) the
current install flow is:

```bash
curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz && \
    tar zxf swiftly-$(uname -m).tar.gz && \
    ./swiftly init --quiet-shell-followup && \
    . "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh" && \
    hash -r

swiftly install latest    # or pin a version, e.g. `swiftly install 6.0.3`
swift --version           # expect 6.0+
```

(The older `curl … swiftly-install.sh | bash` flow is deprecated — that
URL no longer serves the current installer.)

Or grab a tarball directly from <https://swift.org/download/>.

## 2. System dependencies

### GTK3 + WebKitGTK 4.1 (default)

```bash
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    pkg-config \
    libgtk-3-dev \
    libwebkit2gtk-4.1-dev \
    libayatana-appindicator3-dev \
    libglib2.0-dev \
    xvfb \
    wget \
    file \
    zlib1g-dev   # Swift sometimes needs this on minimal images
```

`libayatana-appindicator3-dev` powers `TrayPlugin` (StatusNotifierItem
over D-Bus, with a fallback to `GtkStatusIcon` on legacy desktops).
It's a hard build dep of the GTK3 backend even if you don't use
`TrayPlugin` — the C shim is part of the target.

> The library prints `libayatana-appindicator is deprecated. Please
> use libayatana-appindicator-glib in newly written code.` to stderr
> at startup. Soft deprecation, not a removal — the library still
> works on every distro that has it. Migrating the shim to the GTK-
> free `libayatana-appindicator-glib` is queued for v0.5+ (bundled
> with finally enabling the GTK4 tray); see the
> [README Roadmap](../README.md#roadmap).

Sanity-check the headers are findable:

```bash
pkg-config --modversion gtk+-3.0                       # any 3.x
pkg-config --modversion webkit2gtk-4.1                 # any 2.4x
pkg-config --modversion ayatana-appindicator3-0.1      # any 0.5.x+
```

### GTK4 + WebKitGTK 6.0

```bash
sudo apt-get install -y \
    build-essential \
    pkg-config \
    libgtk-4-dev \
    libwebkitgtk-6.0-dev \
    libglib2.0-dev \
    xvfb \
    wget \
    file \
    zlib1g-dev
```

Sanity-check:

```bash
pkg-config --modversion gtk4               # any 4.x
pkg-config --modversion webkitgtk-6.0      # any 2.4x
```

## 3. Optional — AppImage tooling (only needed for `swift-pwa build --target linux`)

```bash
sudo wget -O /usr/local/bin/linuxdeploy \
    https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
sudo wget -O /usr/local/bin/linuxdeploy-plugin-appimage \
    https://github.com/linuxdeploy/linuxdeploy-plugin-appimage/releases/download/continuous/linuxdeploy-plugin-appimage-x86_64.AppImage
sudo chmod +x /usr/local/bin/linuxdeploy /usr/local/bin/linuxdeploy-plugin-appimage
```

## 4. Clone and build

```bash
git clone https://github.com/tophatch/swift-pwa
cd swift-pwa

# GTK3 build (default).
swift build

# Or, GTK4 build.
SWIFT_PWA_GTK4=1 swift build

# Run unit tests (Core + CLI). Backend-agnostic; always works headless.
swift test --filter SwiftPWACoreTests
swift test --filter SwiftPWACLITests
```

Each build prints which backend it selected, e.g.:

```text
swift-pwa: Linux backend selection = GTK4 + WebKitGTK 6.0
```

If that line says GTK3 when you wanted GTK4 (or vice versa), it's
almost always SwiftPM's manifest cache. The env var is read during
manifest evaluation, but SwiftPM hashes `Package.swift` to decide
whether to re-evaluate — env-var-only changes don't invalidate the
cache. **Run `swift package clean` (or `rm -rf .build`) before
toggling between backends.**

The `SWIFT_PWA_GTK4` env var swaps which system-library targets are in
the SwiftPM package graph, so `pkg-config` only resolves the deps for
the backend you're actually building. The Apple `WKWebViewTests` target
won't build on Linux (gated by `#if canImport(WebKit)`), so SwiftPM
skips it.

### Ubuntu 26.04: libxml2 SONAME mismatch

Ubuntu 26.04 ships `libxml2.so.16`, but Swiftly's bundled toolchain
(at least through 6.0.x) was built against `libxml2.so.2` and refuses
to start until it can find that SONAME. Symlink the new library to
the old name:

```bash
sudo ln -s /usr/lib/x86_64-linux-gnu/libxml2.so.16 \
           /usr/lib/x86_64-linux-gnu/libxml2.so.2
```

Cosmetic on 24.04 (a `libxml2.so.2: no version information available`
warning was the original symptom of this drift); on 26.04 the toolchain
won't run at all without the symlink.

## 5. Run the example

```bash
# Display required for any GUI run.
swift run --package-path Examples/HelloPWA HelloPWA
# or, GTK4:
SWIFT_PWA_GTK4=1 swift run --package-path Examples/HelloPWA HelloPWA
```

If you're SSH'd in headlessly:

```bash
# Run inside Xvfb so it doesn't need a real display.
Xvfb :99 -screen 0 1280x720x24 &
DISPLAY=:99 swift run --package-path Examples/HelloPWA HelloPWA &
sleep 2
# Take a screenshot to prove it rendered.
DISPLAY=:99 import -window root /tmp/swift-pwa.png
```

## 6. Build an `.AppImage`

Easiest is to install the prebuilt CLI from the latest release:

```bash
curl -L https://github.com/tophatch/swift-pwa/releases/latest/download/swift-pwa-linux-x86_64 \
    -o /usr/local/bin/swift-pwa
chmod +x /usr/local/bin/swift-pwa

swift-pwa init MyApp
cd MyApp
swift-pwa build --target linux
# → build/MyApp-x86_64.AppImage
./build/MyApp-x86_64.AppImage
```

Or build the CLI from a swift-pwa checkout (useful when you're
hacking on the bundler itself):

```bash
swift build --product swift-pwa
cd Examples/HelloPWA
../../.build/debug/swift-pwa build --target linux
# → build/HelloPWA-x86_64.AppImage
./build/HelloPWA-x86_64.AppImage
```

## 7. Optional — On-device AI (llama.cpp, Vulkan)

The portable on-device AI backend (`SwiftPWALlama` / `LlamaBackend`) runs a
GGUF model locally, **GPU-accelerated via Vulkan** on Linux x86_64 — one
build covers NVIDIA + AMD + Intel through the driver's Vulkan ICD, with CPU
fallback when no capable device is present. It's the same backend and the
same `pwa.json` flag as Apple; only the GPU path differs (Metal → Vulkan).
See [docs/ai-plugin.md](ai-plugin.md#available-backend-llamacpp) for the API.

Enable it per app in `pwa.json`:

```json
{
  "ai": { "local_llama": true }
}
```

**Build-time prerequisite:** the Vulkan loader's dev package, so the link
step resolves `-lvulkan`:

```bash
sudo apt-get install -y libvulkan-dev
```

Then build as usual — `swift-pwa build --target linux` sees the flag,
downloads the prebuilt `libllama.a` (checksum-verified, cached under
`~/.cache/swift-pwa/llama-linux/`), and links it:

```bash
swift-pwa build --target linux
```

**Runtime prerequisite:** the end user's machine needs a **Vulkan 1.2+
driver / ICD** for GPU acceleration (Mesa for AMD/Intel — `mesa-vulkan-drivers`
— or the proprietary NVIDIA driver). With no usable ICD the model still runs
on the CPU. `linuxdeploy` bundles the Vulkan *loader* (`libvulkan.so.1`) into
the AppImage automatically; the ICD and GPU driver come from the host.

Building the lib yourself (when hacking on swift-pwa, or to produce the
release artifact) uses [`Scripts/build-llama-linux.sh`](../Scripts/build-llama-linux.sh),
which needs the **Vulkan SDK** (for `glslc` + SPIRV-Headers — `libvulkan-dev`
alone is not enough). Install the [LunarG SDK](https://vulkan.lunarg.com/sdk/home#linux),
`source <sdk>/setup-env.sh`, run the script, then point the build at the
result with `SWIFT_PWA_LLAMA_LINUX_LIB_DIR=…/Vendor/llama-linux`.

## 8. Optional — On-device segmentation (`ai.vision.*`, ONNX Runtime)

Promptable image segmentation (`MobileSAMBackend`, SAM-family) runs on Linux
x86_64 via Microsoft's prebuilt **CPU** ONNX Runtime. Same `pwa.json` opt-in
shape as llama:

```json
{
  "ai": { "local_onnx_runtime": true }
}
```

`swift-pwa build --target linux` then downloads the checksum-pinned
`libonnxruntime.so` (cached under `~/.cache/swift-pwa/onnxruntime-linux/`),
links it, and hands it to `linuxdeploy --library` so it's bundled into the
AppImage (SONAME-correct). No system package is needed — the runtime is
self-contained; image decode uses a vendored stb_image, so there's no
CoreGraphics dependency. See [docs/ai-plugin.md](ai-plugin.md) and the
[segmentation proposal](proposals/segmentation-plugin.md) for the API.

> **Swift 6.1+ required for this target.** The `SwiftPWASegmentation` target's
> actor-isolated error-mapping helper trips a strict-concurrency diagnostic on
> Swift 6.0.x that region-based isolation in 6.1 resolved. The rest of
> swift-pwa still builds on 6.0; only `ai.local_onnx_runtime` needs 6.1+.

Building/publishing the vendored lib yourself uses
[`Scripts/vendor-onnxruntime-linux.sh`](../Scripts/vendor-onnxruntime-linux.sh)
(then `SWIFT_PWA_ONNXRUNTIME_LINUX_LIB_DIR=…/Vendor/onnxruntime-desktop/linux-x86_64`).

### GPU acceleration (`ai.onnx_gpu`, NVIDIA CUDA)

To run the segmentation encoder/decoder on an **NVIDIA GPU** instead of the
CPU, add the sibling flag (it implies `ai.local_onnx_runtime`):

```json
{
  "ai": { "local_onnx_runtime": true, "onnx_gpu": true }
}
```

`swift-pwa build --target linux` then vendors the checksum-pinned **CUDA 12**
ONNX Runtime — three shared libs (the runtime, the shared-provider bridge, and
the CUDA execution provider, ~366 MB) — and bundles all three into the AppImage.
At runtime the CUDA EP is tried first and the app **falls back to the CPU
transparently** if a GPU can't be used, so the same AppImage runs on machines
without an NVIDIA GPU. `ai.vision.info` reports the active `provider`
(`"cuda"` or `"cpu"`).

> **The CUDA runtime + cuDNN are *not* bundled** — they're expected on the
> target machine, and ONNX Runtime pins the **major** versions it was built
> against (ORT 1.27 → CUDA 12.x + cuDNN 9.x). Install NVIDIA's CUDA 12 toolkit +
> cuDNN 9 (e.g. via NVIDIA's apt repo). A missing or mismatched CUDA runtime is
> not an error — the CUDA EP just fails to load and the app runs on CPU (a
> one-line notice on stderr; `ai.vision.info` reports `"cpu"`). This brittleness
> is why Linux GPU is CUDA/NVIDIA-only and behind an explicit opt-in.

There is **no** cross-vendor prebuilt GPU path on Linux (unlike Windows
DirectML, and unlike llama.cpp's single Vulkan build): AMD Radeon iGPUs aren't
ROCm targets and ONNX Runtime ships no native Vulkan/WebGPU EP, so AMD/Intel
parts stay on the CPU here. See
[docs/proposals/onnx-gpu-execution-providers.md](proposals/onnx-gpu-execution-providers.md)
for the full matrix. Vendoring the GPU libs yourself uses
[`Scripts/vendor-onnxruntime-linux-gpu.sh`](../Scripts/vendor-onnxruntime-linux-gpu.sh)
(then `SWIFT_PWA_ONNXRUNTIME_LINUX_GPU_LIB_DIR=…/Vendor/onnxruntime-desktop-gpu/linux-x86_64`).

## Known limitations on Linux

The Linux backends are hand-rolled against the GTK / WebKitGTK C APIs.
End-to-end functionality is in place on both — JS `__SWIFT_PWA__.invoke()` /
`subscribe()` round-trip through the bridge — but a few rough edges
remain:

- **`Window.position()` / `setPosition` / `.didMove` are no-ops on the
  GTK4 backend.** GTK4 dropped the position APIs entirely (Wayland
  refuses to give apps their own position; CSD makes the concept
  ambiguous). `position()` returns `.zero`, `setPosition` silently
  no-ops, and `.didMove` events are never emitted on GTK4. The GTK3
  backend supports all three. **Consequence for window state memory**
  (`window.remember_state`): GTK3 restores both size and position, but
  **GTK4 restores size only** — since it can neither read nor set a
  position, none is ever saved, and the window opens at its remembered
  size wherever the compositor places it. Off-screen restore (a monitor
  that was present when the geometry was saved is now gone) isn't clamped
  yet on any backend.
- **WM-driven focus / minimize / fullscreen events aren't observed.**
  `WindowEvent.didFocus` / `.didBlur` / `.didMinimize` / `.didDeminiaturize`
  / `.didEnterFullscreen` / `.didExitFullscreen` are only emitted when
  the corresponding `Window.focus()` / `minimize()` / `setFullscreen()`
  method is called programmatically. User-driven state changes (alt-tab,
  click another window, double-click titlebar to maximize) don't reach
  subscribers on either backend. The fix is to wire GTK3's
  `focus-in-event` / `focus-out-event` / `window-state-event`, or
  GTK4's `notify::is-active` / `notify::fullscreened` / `notify::minimized`,
  the same way the resize signals are hooked. Note that *programmatic*
  fullscreen state **is** tracked: `Window.isFullscreen()` reflects the
  last `setFullscreen(_:)` call (and the initial `window.fullscreen`
  config) on both backends — it just doesn't yet observe a WM/F11-driven
  toggle.
- **No `system.memoryPressure` event.** `system.memory` works (total RAM,
  plus `availableBytes` from `/proc/meminfo`'s `MemAvailable`), but Linux has
  no portable per-process memory-pressure signal, so the
  `system.memoryPressure` event never fires here (it does on
  iOS/macOS/Android). Size memory-scaled caches from a `system.memory` read
  rather than relying on the push event, and treat the event as best-effort.
- **AppImage builds need a real PNG icon.** If `pwa.json.icon` is
  absent or non-PNG, the bundler embeds a transparent placeholder
  so `linuxdeploy` doesn't hang on its prompt path. The build prints a
  one-line icon summary (`swift-pwa: app icon ← icon.png`, or the
  fallback reason) so a placeholder substitution isn't silent.
- **On-device llama.cpp is x86_64-only on Linux.** The prebuilt
  `libllama.a` (see §7) is published for x86_64; arm64 Linux isn't built
  yet, so `ai.local_llama` on a `--target linux` build from an aarch64
  host reports that and is skipped. GPU acceleration further needs a
  Vulkan 1.2+ driver/ICD at runtime — without one the model falls back to
  the CPU rather than failing.
- **Swiftly's bundled toolchain prints noisy warnings** on Ubuntu
  (`libxml2.so.2: no version information available`, `prohibited
  flag(s): -pthread`). Cosmetic; ignore.
- **`BiometricAuthPlugin` is unsupported on Linux.** There is no
  cross-distro biometric primitive that maps cleanly onto a
  per-app library: `libfprint` only covers a subset of fingerprint
  readers and isn't preinstalled, polkit gives root-style
  authorization rather than a "prove the user is here" prompt,
  and PAM is system-level configuration that an app shouldn't
  poke at. The Linux `SystemBiometricAuth` always reports
  `available: false` (`reason: "biometric authentication is not
  supported on Linux"`); `authenticate` returns `authenticated:
  false` with the same string in the `error` field rather than
  throwing — apps can fall back to a passphrase flow and treat
  the `available` flag as the universal cue.
- **GTK4 dialogs require GTK 4.10+.** `DialogPlugin` on the GTK4
  backend is wired through `GtkAlertDialog` (message + confirm) and
  `GtkFileDialog` (open / save / directory), both added in GTK 4.10.
  Older GTK4 versions will fail at link time on the
  `swiftpwa_alert_dialog_run` / `swiftpwa_file_dialog_run` symbols.
  Either upgrade GTK or stick with the default GTK3 backend (which
  uses `GtkMessageDialog` / `GtkFileChooserDialog` and has no version
  floor beyond what WebKitGTK 4.1 itself requires).
- **Auto-updater is `in_place` only on Linux.** `LinuxAppImageUpdater`
  ships in v0.4 and covers the full download → Ed25519 verify →
  atomic-rename → relaunch pipeline against the running AppImage's
  path (read from the `APPIMAGE` env var the AppImage runtime sets).
  The `pwa.json` `updater.linux.appimage_strategy` field is reserved
  for a future iteration that adds `side_by_side` (write the new
  AppImage alongside the old and update a `~/.local/bin` symlink
  rather than swapping in place). See [docs/auto-updates.md](auto-updates.md)
  for the full publishing flow.
- **Content packs are fully supported.** `fs.extractZip` / `fs.listZip` /
  `fs.createZip` use ZIPFoundation (Linux links it the same as Apple), and
  `ctx.serveDirectory(_:at:)` serves through the `pwa://localhost`
  scheme handler with HTTP `Range` / `206 Partial Content` support on
  **both** GTK backends — a seeked `GFileInputStream` streams a
  multi-GB `.webm` off disk rather than buffering it, verified headless
  on WebKitGTK 6.0. No Linux-specific caveat beyond the usual GTK
  backend selection.

If you hit linker errors around `webkit_*` symbols, the most common
cause is `pkg-config --libs <module>` returning empty — confirm with:

```bash
pkg-config --libs webkit2gtk-4.1     # GTK3 backend
pkg-config --libs webkitgtk-6.0      # GTK4 backend
```

If the output is empty, your dev package install is broken. Reinstall.

## Threading model on Linux

Worth knowing if you read the source: Swift's `MainActor` executor on
Linux is libdispatch's main queue, which neither `gtk_main()` (GTK3)
nor a bare `g_main_loop_run` (GTK4) pumps. That means
`await MainActor.run { … }` from a cooperative-pool task hangs forever
once the GTK loop is running. swift-pwa works around this with a
[`MainThread.run`](../Sources/SwiftPWACore/MainThread.swift) abstraction
whose hook both GTK runtimes point at `g_idle_add`. If you write your
own commands that need to touch GTK from a non-main thread, use
`MainThread.run` rather than `MainActor.run` and you'll avoid the
deadlock.

### `swift test` occasionally hangs at exit on Linux

The same libdispatch main queue is behind an intermittent flake when you
run the test suite on Linux: every test passes, then the process **fails
to exit**. A swift-testing bundle's async `@main` parks the main thread in
`dispatch_main()` (`swift_task_asyncMainDrainQueue`) after the run
completes, waiting for the wakeup that fires the final `exit()` — and that
wakeup is intermittently lost (a swift-corelibs-libdispatch main-queue
race). It reproduces on Swift 6.0.3 **and** 6.2.0 (so it isn't
toolchain-specific), independent of which tests run and of `--no-parallel`,
and lately runs *hot* — a majority of runs park at exit — so it can't be
waited out with a couple of retries. It always clears on a fresh process.

This is purely a *process-exit* hang — the tests themselves have already
passed. A timeout-and-retry wrapper handled it for a while, but the flake
runs hot enough on the hosted gtk runners that blind retries began failing
otherwise-green jobs (the hang eats `swift test`'s stdout summary, so a
wrapper can't tell "passed then hung" from "hung mid-run"). CI now runs the
Linux test step through [`Scripts/ci-test-linux.sh`](../Scripts/ci-test-linux.sh),
which sidesteps that entirely: it launches the **built test bundle directly**
(`swift build --build-tests` runs first) and has swift-testing write its
**structured event stream to a file** (`--event-stream-output-path`). Two
facts make that robust:

- A failed expectation is written as a `"symbol":"fail"` issue event
  *mid-run*, flushed with the bulk of the stream — so **failures are always
  observed and reported, never masked**.
- Because the hang is *post-run*, the pass signal is the hang itself: once the
  bundle has run tests and gone **quiescent** (no new events for several
  seconds while still alive) with no failure recorded, the run passed and the
  script kills the parked process. (`runEnded`, when it happens to flush
  before the hang, is a fast path to the same verdict.)

swift-testing block-buffers the event stream, so its trailing chunk is often
lost to the exit-hang's kill — which is exactly why the verdict comes from the
mid-run failure events + the quiescence signal, not the trailing `runEnded`. A
test process that instead *crashes* at exit (the other face of the same
swift-corelibs race — no verdict written) is retried; a deterministic crash
recrashes and fails the job.

If you hit the hang locally, build once (`swift build --build-tests`) then
invoke the wrapper (`bash Scripts/ci-test-linux.sh`), or just re-run `swift
test`. See issue #39 for the full investigation, including the dead ends
(stdout `stdbuf`, `--xunit-output`, `| tee`, SIGCONT-nudging) and the one
documented caveat: a test that hung *mid-run* with no output would be
indistinguishable from the post-run park — the suite has no such test.

## Reporting issues

When filing a Linux issue, include:

```bash
swift --version
lsb_release -a
echo "SWIFT_PWA_GTK4=${SWIFT_PWA_GTK4:-unset}"
# GTK3:
pkg-config --modversion gtk+-3.0 webkit2gtk-4.1 2>/dev/null
# GTK4:
pkg-config --modversion gtk4 webkitgtk-6.0 2>/dev/null
```
