# swift-pwa on Windows (Win32 + WebView2)

The Windows backend wraps `WKWebView`'s closest cousin — Microsoft Edge
WebView2 — through a small C++ COM shim, plus Win32 for window
management, clipboard, tray, and balloon notifications. Swift on
Windows handles the rest via `import WinSDK`.

> **Status:** verified end-to-end against `Examples/HelloPWA` on
> Windows 11 ARM64 (Swift 6.3.1, Visual Studio 2026, WebView2 SDK
> 1.0.3912.50, WIL 1.0.260126.7); x64 builds clean on every commit
> via the `windows-2022` CI runner. Window lifecycle, JS↔Swift
> bridge, clipboard, tray, WinRT toast notifications, Per-Monitor V2
> DPI scaling, and the `Ctrl+Alt+J` DevTools shortcut are all in scope.
> MSIX packaging and the opt-in Evergreen Bootstrapper land in the
> CLI bundler. Richer toast XML (action buttons, scheduled toasts)
> waits on a follow-up.

## 1. Toolchain

| Component                              | Install                                                                                         |
|----------------------------------------|-------------------------------------------------------------------------------------------------|
| Swift 6.0+ for Windows                 | <https://www.swift.org/install/windows/> — or `winget install --id Swift.Toolchain`             |
| Visual Studio Build Tools              | "Desktop development with C++" workload — supplies `cl.exe`, MSVC libs, the Windows 10/11 SDK   |
| WebView2 SDK                           | NuGet package `Microsoft.Web.WebView2` (≥ 1.0.2210)                                             |
| Windows Implementation Libraries (WIL) | NuGet package `Microsoft.Windows.ImplementationLibrary` — `<wil/com.h>` is used by the COM shim |
| WebView2 Runtime                       | <https://developer.microsoft.com/microsoft-edge/webview2/> (preinstalled on Windows 11)         |

The Swift installer wires `import WinSDK` to the Visual Studio /
Windows SDK headers; you don't need any extra plumbing for Win32.

## 2. WebView2 SDK + WIL on the build path

`Sources/CWebView2Shim/swiftpwa_webview2.cpp` includes `<WebView2.h>`
and `<wil/com.h>`, and links `WebView2LoaderStatic.lib`:

- `<WebView2.h>` and the static loader come from the
  `Microsoft.Web.WebView2` NuGet package, which ships per-arch
  loaders under `build/native/{x86,x64,arm64}/WebView2LoaderStatic.lib`.
- `<wil/com.h>` comes from `Microsoft.Windows.ImplementationLibrary`
  (header-only).

```powershell
# In your project root, fetch both NuGet packages:
nuget install Microsoft.Web.WebView2 -OutputDirectory packages -ExcludeVersion
nuget install Microsoft.Windows.ImplementationLibrary -OutputDirectory packages -ExcludeVersion
```

Then enter a Visual Studio Developer Shell with the right architecture
*before* setting INCLUDE/LIB and building. The default PowerShell
session inherits the system `LIB`, which on a fresh box may point at
x86 MSVC libs and produce confusing link-time errors like
`msvcrt.lib(chkstk.obj): machine type x86 conflicts with arm64`.

```powershell
# x64 host:
& "C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\Launch-VsDevShell.ps1" -Arch amd64 -HostArch amd64

# arm64 host:
& "C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\Launch-VsDevShell.ps1" -Arch arm64 -HostArch arm64
```

(Adjust the path for VS 2022 / a non-Community edition.)

```powershell
# Pick the arch matching your Swift toolchain. PROCESSOR_ARCHITECTURE
# is "AMD64" on x64 and "ARM64" on Windows-on-ARM.
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
$env:INCLUDE = "$pwd\packages\Microsoft.Web.WebView2\build\native\include;" +
               "$pwd\packages\Microsoft.Windows.ImplementationLibrary\include;" +
               "$env:INCLUDE"
$env:LIB     = "$pwd\packages\Microsoft.Web.WebView2\build\native\$arch;$env:LIB"

swift build -c release
```

The static loader (`WebView2LoaderStatic.lib`) is what `Package.swift`
asks for — that means apps don't need to ship `WebView2Loader.dll`
alongside the executable. The WebView2 Runtime itself still has to be
installed; `WindowsAppRuntime` checks for it on startup and prints an
install hint if it's missing.

(If you'd rather pull the SDK via vcpkg, `vcpkg install
microsoft-web-webview2:x64-windows` — or `:arm64-windows` — resolves
the same headers and loader. WIL is also available as
`vcpkg install wil`. Make sure the vcpkg-installed `lib/` dir is on
`LIB`.)

### Per-session prerequisites

`Launch-VsDevShell.ps1` is **per PowerShell session** — every fresh
window needs the VS Developer environment loaded again before
`swift build` will resolve the MSVC toolchain. (Reproducing what
`vsdevcmd.bat` does ourselves is fragile, so we leave it to VS.)

**Auto-loading it.** PowerShell's profile (`$PROFILE`) is the .zshrc
analogue and will run on every shell launch, but most VS users *don't*
auto-load `Launch-VsDevShell.ps1` globally and you probably shouldn't
either:

- VsDevShell mutates ~50 env vars. MSVC's `link.exe` jumps to the
  front of `$env:Path`, shadowing GNU `link` and any other tools
  with colliding names.
- It locks the session to one arch (x64 *or* arm64) and one VS
  install — switching means a fresh shell anyway, defeating the
  point.
- It adds 1–3s to every PowerShell startup, including non-dev
  sessions.

The cleaner per-context options:

- **Windows Terminal profile** — add a "VS Dev" profile in *Settings
  → Profiles → Add new* with `commandline` set to:

  ```text
  powershell.exe -NoExit -Command "& 'C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\Launch-VsDevShell.ps1' -Arch amd64 -HostArch amd64"
  ```

  Default profile stays clean; you pick the dev tab when you need it.

- **VS Code workspace terminal** — drop a `.vscode/settings.json` in
  your swift-pwa-using project that overrides
  `terminal.integrated.profiles.windows` and
  `terminal.integrated.defaultProfile.windows`:

  ```json
  {
    "terminal.integrated.profiles.windows": {
      "VS Dev PowerShell": {
        "path": "powershell.exe",
        "args": ["-NoExit", "-Command",
          "& 'C:\\Program Files\\Microsoft Visual Studio\\18\\Community\\Common7\\Tools\\Launch-VsDevShell.ps1' -Arch amd64 -HostArch amd64"]
      }
    },
    "terminal.integrated.defaultProfile.windows": "VS Dev PowerShell"
  }
  ```

  Per-workspace, no global pollution.

- **Project-local script** — save the loader + (optional) NuGet
  exports as `vendor\Set-SwiftPwaEnv.ps1` and dot-source it (`. .\vendor\Set-SwiftPwaEnv.ps1`)
  whenever you open a fresh shell on the project. Lowest blast
  radius, slight per-session friction.

If you do go the `$PROFILE` route anyway, gate it on the working
directory so non-dev sessions stay clean:

```powershell
# In $PROFILE
if ((Get-Location).Path -like "*\swift-pwa*") {
    & "C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\Launch-VsDevShell.ps1" -Arch amd64 -HostArch amd64
}
```

The WebView2 + WIL `INCLUDE` / `LIB` exports were also a per-session
chore in v0.2; in v0.3 the bundler auto-detects the swift-pwa repo's
`packages/` folder and prepends the matching directories to
`INCLUDE` / `LIB` before launching `swift build`. Walk order, from
the project being bundled:

  1. `<projectRoot>/packages/...` — running inside the swift-pwa repo
  2. `<projectRoot>/../packages/...` — running from a sibling
     directory like `Examples/HelloPWA`
  3. `<projectRoot>/../../packages/...`
  4. `<projectRoot>/.build/checkouts/swift-pwa/packages/...` — when
     swift-pwa is pulled as a git dependency

If any of those resolves, you'll see:

```text
swift-pwa: prepending swift-pwa NuGet packages to INCLUDE / LIB
  WebView2: …\Microsoft.Web.WebView2\build\native\include
  WIL:      …\Microsoft.Windows.ImplementationLibrary\include
  Loader:   …\Microsoft.Web.WebView2\build\native\x64
```

If you're invoking `swift build` directly (e.g. plain `swift build -c
release` outside the bundler), the auto-detect doesn't run and you
still need the manual exports:

```powershell
# Reuse the swift-pwa repo's NuGet packages from any sibling project:
$arch     = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
$swiftpwa = "C:\path\to\swift-pwa"  # absolute path to the swift-pwa checkout
$env:INCLUDE = "$swiftpwa\packages\Microsoft.Web.WebView2\build\native\include;" +
               "$swiftpwa\packages\Microsoft.Windows.ImplementationLibrary\include;" +
               "$env:INCLUDE"
$env:LIB     = "$swiftpwa\packages\Microsoft.Web.WebView2\build\native\$arch;$env:LIB"
```

Symptoms of forgetting:

| Missing                    | Failure mode                                                                                                                                                          |
|----------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `Launch-VsDevShell.ps1`    | `lld-link: error: could not open 'msvcrt.lib'` — even at the manifest-compile stage.                                                                                  |
| `INCLUDE` (WebView2 / WIL) | `CWebView2Shim`: `'WebView2.h' file not found` or `'wil/com.h' file not found`. Plain `swift build` only — the bundler auto-injects these.                            |
| `LIB`                      | `lld-link: error: could not open 'WebView2LoaderStatic.lib'`. Plain `swift build` only — same auto-inject.                                                            |
| stdlib junction            | `error: unable to load standard library for target 'x86_64-unknown-windows-msvc'`. See [One-time stdlib junction](#one-time-stdlib-junction-swift-asserts-installer). |

### One-time stdlib junction (Swift `+Asserts` installer)

The official Swift Windows installer ships two toolchain trees:
`Toolchains\6.x.y+Asserts` (the default on PATH) and `Platforms\6.x.y\Windows.platform\Developer\SDKs\Windows.sdk`.  
The `+Asserts` tree intentionally omits a `lib\swift\windows` directory — it
expects `swiftc` to resolve the stdlib via `SDKROOT`. However, SwiftPM's
manifest compiler (`swift package`) invokes `swiftc` directly without that
variable, so on a fresh install you get:

```
<unknown>:0: error: unable to load standard library for target 'x86_64-unknown-windows-msvc'
error: 'swift-pwa': Invalid manifest
```

The fix is a one-time directory junction that makes the Platform SDK's stdlib
visible where the toolchain expects it:

```powershell
# Run once after installing Swift (adjust the version number if needed):
$base = "$env:LOCALAPPDATA\Programs\Swift"
New-Item -ItemType Junction `
    -Path  "$base\Toolchains\6.3.1+Asserts\usr\lib\swift\windows" `
    -Target "$base\Platforms\6.3.1\Windows.platform\Developer\SDKs\Windows.sdk\usr\lib\swift\windows"
```

The junction survives reboots and only needs to be recreated if you reinstall
or upgrade Swift. Verify it worked:

```powershell
Test-Path "$env:LOCALAPPDATA\Programs\Swift\Toolchains\6.3.1+Asserts\usr\lib\swift\windows\x86_64\swiftCore.lib"
# → True
```

### Windows on ARM

The backend is architecture-clean — no inline asm, no x86 intrinsics,
the C++ shim is just COM + Win32 + header-only WRL/WIL — so it builds
for `aarch64-pc-windows-msvc` the same way it does for x64.

| Host           | Swift toolchain                           | WebView2 lib path                               |
|----------------|-------------------------------------------|-------------------------------------------------|
| Windows x64    | `swift-6.x.y-RELEASE-windows10.exe`       | `build/native/x64/WebView2LoaderStatic.lib`     |
| Windows on ARM | `swift-6.x.y-RELEASE-windows10-arm64.exe` | `build/native/arm64/WebView2LoaderStatic.lib`   |

Caveats specific to ARM:

- **Build natively on the ARM box.** Swift-for-Windows's cross-compile
  story (x64 host → arm64 target, or vice versa) is still rough at the
  SDK-layout layer. Running `swift build` on an ARM64 install of
  Windows is the path that "just works" today.
- **The portable bundle is host-arch.** `swift run swift-pwa build
  --target windows` produces a folder containing whatever
  `swift build -c release` emitted on the calling machine — Swift's
  cross-compile is still rough enough that we don't try to drive it
  from the bundler. To ship both architectures, build twice on the
  matching hosts (or via two CI runners) and label the output
  folders `MyApp-arm64/` and `MyApp-x64/`. For MSIX, `--arch arm64`
  / `--arch x64` controls the `<Identity ProcessorArchitecture>`
  attribute the OS validates against — the value must match the
  EXE's actual architecture (i.e. the host's Swift toolchain), or
  `Add-AppxPackage` rejects the install with "doesn't match this
  device".
- **WebView2 Runtime is preinstalled** on Windows 11 ARM and on
  Windows 10 ARM since the 21H2 update. Older ARM boxes (the
  original Surface Pro X on 1809/1903) are the only realistic
  install-prompt scenario; the runtime detection in
  `WindowsAppRuntime` covers it.

## 3. Build & run

Easiest is to grab the prebuilt CLI from the latest GitHub release
(added to the matrix in v0.3) and put it on your PATH:

```powershell
Invoke-WebRequest `
    -Uri https://github.com/tophatch/swift-pwa/releases/latest/download/swift-pwa-windows-x86_64.exe `
    -OutFile $env:USERPROFILE\bin\swift-pwa.exe
# Make sure $env:USERPROFILE\bin is on $env:Path.

swift-pwa init MyApp
cd MyApp
swift-pwa build --target windows                       # → build\MyApp\MyApp.exe (+ web/, pwa.json)
```

To update the CLI later, re-run the `Invoke-WebRequest` above with the
new release. (`swift-pwa self-update` is macOS / Linux only — Windows
can't replace a running `.exe`, so it just prints these manual steps.)

Or build the CLI from a swift-pwa checkout (useful when you're
hacking on the bundler itself — same dance as the iOS / macOS docs):

```powershell
swift build                                            # debug
swift build -c release                                 # ship build
swift run swift-pwa init MyApp                         # scaffold a project
swift run swift-pwa build --target windows             # → build\MyApp\MyApp.exe (+ web/, pwa.json)
```

The bundler produces a portable folder. Drop it on any Windows 10 21H2+
or Windows 11 box that has the WebView2 Runtime, and double-click
`MyApp.exe`.

The bundled EXE is flipped to the **WINDOWS** subsystem (via `editbin
/SUBSYSTEM:WINDOWS`) so it launches as a GUI app with no stray console
window — SwiftPM otherwise links it as a console app, which makes Explorer
open a terminal alongside the window. `editbin` ships with the MSVC toolset
and is on PATH inside a VS Developer shell; if it's missing the build still
succeeds but warns, and the EXE keeps its console. (A consequence: `print` /
stderr don't appear when the app is launched from Explorer — use `swift run`
during development to see logs.)

### Single-file distribution

To ship the portable app as **one self-contained `.exe`** instead of a folder,
add `--single-file`:

```powershell
swift run swift-pwa build --target windows --single-file   # → build\MyApp.exe (just the exe)
```

This embeds `web/` as an overlay appended to the exe; at runtime the app reads
its own executable and serves the bundle from memory (no extraction, no sibling
`web/`/`pwa.json`). A `.bundled(directory:)` app needs no code change — the
runtime serves the embedded assets when present and falls back to disk `web/`
otherwise. Current limits: assets are served as full-body responses (no HTTP
range — ship large media via `ctx.serveDirectory(_:at:)`, which stays
range-aware off disk), the overlay is uncompressed, and there's no SPA
deep-link fallback (a request for an unknown path 404s rather than returning
`index.html`). Not combinable with `--package-format msix` (MSIX already
packages everything into one installable). Code-signing a single-file exe
(Authenticode over the overlay) isn't wired yet.

For an MSIX/Appx package instead of a portable folder:

```powershell
swift run swift-pwa build --target windows --package-format msix
swift run swift-pwa build --target windows --package-format msix --arch arm64
swift run swift-pwa build --target windows --package-format msix --sign <thumbprint-or-pfx>
```

The bundler stages the EXE, web bundle, a generated `AppxManifest.xml`,
and a `Square150x150Logo.png` (taken from `pwa.json`'s `icon` if
provided, otherwise a 1×1 placeholder), then drives `makeappx.exe pack`
and — if `--sign` is supplied — `signtool.exe sign`. Both binaries
ship with the Windows SDK; no extra install needed once you've launched
the VS Developer Shell. `--arch` is one of `x64` (default), `x86`, or
`arm64`; it sets `<Identity ProcessorArchitecture>` and must match the
host Swift toolchain's architecture (we don't cross-compile). The
signed MSIX installs on any Windows 10 1809+ box; an unsigned MSIX is
sideloadable on developer-mode boxes only.

To embed the WebView2 Evergreen Bootstrapper (~1.7 MB) in either the
portable bundle or the MSIX so the app can self-install the runtime:

```powershell
swift run swift-pwa build --target windows --bootstrap-webview2
```

`WindowsAppRuntime` detects a missing runtime at startup, finds
`MicrosoftEdgeWebview2Setup.exe` next to the EXE, and prompts the user
via a MessageBox before `ShellExecuteEx`-ing it with elevation.

## 4. Optional — On-device AI (llama.cpp)

The portable on-device AI backend (`SwiftPWALlama` / `LlamaBackend`) runs a
GGUF model locally. It's the same backend and the same `pwa.json` flag on every
platform; what differs by architecture is the compute path:

|Host arch|Compute|Notes|
|---|---|---|
|**x64**|**Vulkan GPU** (CPU fallback)|One build covers NVIDIA + AMD + Intel via the driver's Vulkan ICD.|
|**arm64** (Snapdragon X Copilot+)|**CPU**|Runs on the CPU. Small models (0.5–3B) are comfortable on Snapdragon X. (A GPU path exists but is experimental — see below.)|

On **arm64** this is also the *unpackaged, any-GGUF, no-token* fallback to
[Phi Silica](#5-on-device-ai-phi-silica), whose generation needs an MSIX package
**and** a Microsoft LAF token — llama needs neither. See
[docs/ai-plugin.md](ai-plugin.md#available-backend-llamacpp) for the API.

> **Experimental — arm64 Adreno GPU.** The Snapdragon Adreno *is* a Vulkan 1.3
> device, and the arm64 Vulkan build path works end to end (the LunarG **warm**
> Windows-ARM SDK provides `glslc` + an arm64 `vulkan-1.lib`; ggml-vulkan compiles
> with `clang-cl`; the loader finds the Adreno ICD). **But the Adreno X1's Vulkan
> *compute* currently returns incorrect output** — verified directly: the same
> model + binary is coherent on the CPU and garbage the moment the Adreno is used,
> and it's immune to every ggml-vulkan correctness flag. This is upstream
> (Qualcomm Vulkan driver / ggml shader) immaturity, not swift-pwa. So arm64 ships
> **CPU-only**, and the GPU build is gated behind an opt-in for re-testing as the
> stack matures: build the lib with `LLAMA_WIN_ARM64_VULKAN=1 pwsh
> Scripts/build-llama-windows.ps1 -Arch arm64`, and set the same `LLAMA_WIN_ARM64_VULKAN`
> when building your app so `vulkan-1` links. Do **not** ship it — output is wrong.

Enable it per app in `pwa.json`:

```json
{
  "ai": { "local_llama": true }
}
```

Then build as usual from your VS Developer PowerShell —
`swift-pwa build --target windows` sees the flag, downloads the prebuilt
`llama.lib` (checksum-verified, cached under
`%LOCALAPPDATA%\swift-pwa\llama-windows\`), prepends its directory to `LIB`, and
links it:

```powershell
swift run swift-pwa build --target windows
```

**Build-time prerequisite (x64 only):** the [Vulkan SDK](https://vulkan.lunarg.com/sdk/home#windows),
so the link step resolves `vulkan-1.lib` (the loader import library). Install it
(the winget package id is `KhronosGroup.VulkanSDK`) — it sets `VULKAN_SDK`
machine-wide, and `swift-pwa build` reads `VULKAN_SDK` to add the SDK's `Lib` to
the linker search path automatically (alongside the downloaded `llama.lib`). A
bare GPU driver's `vulkan-1.dll` alone is **not** enough at link time. On
**arm64** the lib is CPU-only, so **no Vulkan SDK is needed** — the build links
`llama.lib` alone.

**Runtime prerequisite (x64):** the end user's machine needs a **Vulkan 1.2+
driver / ICD** for GPU acceleration (the GPU vendor's standard Windows driver
provides both the ICD and `vulkan-1.dll` in `System32`). With no usable ICD the
model still runs on the CPU. On **arm64** inference is on the CPU, so there's no
runtime GPU prerequisite.

Building the lib yourself (when hacking on swift-pwa, or to produce the release
artifact) uses [`Scripts/build-llama-windows.ps1`](../Scripts/build-llama-windows.ps1),
which needs MSVC (`cl.exe` / `lib.exe` on PATH — run from a VS Developer
PowerShell). For **x64** it also needs the **Vulkan SDK** (for `glslc` +
SPIRV-Headers). For **arm64** pass `-Arch arm64` and run from an **arm64**
developer shell (no Vulkan SDK) — but note ggml's CPU backend **refuses MSVC on
ARM** (`"MSVC is not supported for ARM, use clang"`), so the script drives the
arm64 compile with **`clang-cl`** instead of `cl`. It auto-finds one: on PATH,
else the **Swift toolchain's** (the same `usr\bin` as `swift.exe` — so a box with
Swift installed already has it), else a standard LLVM install. Run the script,
then point the build at the result with
`$env:SWIFT_PWA_LLAMA_WINDOWS_LIB_DIR='…\Vendor\llama-windows'`.

## 5. On-device AI: Phi Silica

The `ai.*` plugin's Windows platform built-in is **Phi Silica**, via the
[Windows AI APIs](https://learn.microsoft.com/windows/ai/apis/phi-silica)
(`LanguageModel`) in the **Windows App SDK** — the counterpart to Apple
Foundation Models / Android Gemini Nano. See
[docs/ai-plugin.md](ai-plugin.md#available-backend-windows-phi-silica) for the
cross-platform contract; this section is the Windows build + deployment
specifics.

Turn it on in `pwa.json` and wire the backend:

```json
{ "ai": { "phi_silica": true } }
```

```swift
import SwiftPWAPhiSilica

runtime.run { ctx in
    #if os(Windows)
        ctx.use(AIPlugin(PhiSilicaBackend(unlockToken: myLAFToken)))
    #endif
}
```

`swift-pwa build --target windows` sets `SWIFT_PWA_PHI_SILICA=1` (pulling in the
`SwiftPWAPhiSilica` target + the `CPhiSilica` C++/WinRT shim) and the MSIX
manifest generator declares the `systemAIModels` restricted capability.

**Build prerequisites** (in addition to §2's WebView2/WIL): the **Windows App
SDK** NuGet (`Microsoft.WindowsAppSDK`) must be on the build path. The AI APIs
ship as `.winmd` metadata, so the C++/WinRT projection headers
(`winrt/Microsoft.Windows.AI.Text.h`, …) are generated with `cppwinrt.exe`
against the SDK's `metadata\*.winmd` (`-input <AI metadata> -input <Foundation
metadata> -input sdk`). Put the generated projection dir + the Foundation +
Runtime `include` dirs on `INCLUDE`, and the Foundation
`lib\native\<arch>` (for `Microsoft.WindowsAppRuntime.Bootstrap.lib`) on `LIB`.
The shim bootstraps the runtime via `MddBootstrapInitialize2` using the SDK's
own `WindowsAppSDK-VersionInfo.h` constants. Verified building on **arm64**
(Snapdragon X Copilot+).

**Two hard runtime requirements — both Windows-platform policy, not swift-pwa:**

1. **MSIX package identity.** The Windows AI APIs refuse to run from an
   *unpackaged* exe — `GetReadyState()` returns `CapabilityMissing` and
   generation throws `E_ACCESSDENIED`. swift-pwa's default portable exe
   therefore **cannot** reach Phi Silica; ship it from a
   **`build --target windows --package-format msix`** build (which declares the
   `systemAIModels` capability and the `Microsoft.WindowsAppRuntime` framework
   dependency). With identity in place, `ai.info` reports `available: true` /
   `Ready` on a Copilot+ NPU.
2. **A Limited Access Feature unlock token.** `com.microsoft.windows.ai.languagemodel`
   is a LAF: generation needs a Microsoft-issued token tied to your app's
   package family name (request via the LAF Access Token Request Form linked
   from the Phi Silica docs). Pass it as `PhiSilicaBackend(unlockToken:)` — the
   backend calls `LimitedAccessFeatures.TryUnlockFeature` (the attestation
   string is auto-built from the running package's identity). Without the token,
   the model is `Ready` but `generate` throws *"Limited Access Feature is not
   available"*.

**Hardware.** Phi Silica runs on Copilot+ PC NPUs (best; model pre-installed)
and NVIDIA RTX 30-series+ GPUs (model downloaded on demand via
`ai.ensureModel`); AMD GPU support is "coming soon" upstream. A device that
can't run it reports `available: false` and the app falls back to its own tier.

## 6. Architecture sketch

```
+-----------------------------+        +---------------------------+
| WindowsAppRuntime           |        | CWebView2Shim (C++)       |
|  - SetProcessDpiAwareness   |        |  - CreateCoreWebView2Env  |
|  - SetCurrent..AppUserModel |        |  - CreateController       |
|  - swiftpwa_toast_init(..)  |        |  - WebMessageReceived     |
|  - OleInitialize            |  --->  |  - ExecuteScript          |
|  - install MainThread hook  |        |  - WebResourceRequested   |
|  - GetMessageW / Dispatch   |        |  - swiftpwa_toast_send    |
+-------------+---------------+        |    (C++/WinRT, ToastMgr)  |
              |                        +---------------------------+
              v
+-----------------------------+
| Win32Window                 |  + SystemClipboard (Win32 CB API)
|  - CreateWindowExW          |  + SystemTray (Shell_NotifyIconW)
|  - WM_SIZE → fitTo(client)  |  + SystemNotifications (WinRT toast,
|  - WM_DPICHANGED → resize   |    Shell_NotifyIcon balloon fallback)
|  - DIP ↔ physical px        |
|  - WebView2Adapter          |
+-----------------------------+
```

A few load-bearing details:

- **MainThread hook is a hidden message-only window.** Same reason
  Linux's hook routes through `g_idle_add`: Swift's MainActor
  executor is backed by libdispatch's main queue, which `GetMessageW`
  doesn't pump. `MainThread.run` posts `WM_APP+1` carrying a heap-boxed
  closure to the dispatcher window; its WndProc unboxes and fires.
- **`pwa://`-style content uses a virtual host, not a custom scheme.**
  WebView2 enforces same-origin checks on custom schemes that would
  break ESM imports and `fetch`, so for bundled content we map
  `https://swift-pwa.local/` to the bundle directory via
  `SetVirtualHostNameToFolderMapping` and navigate there. The C shim
  also exposes `WebResourceRequested`-style interception for callers
  who really want a custom scheme; `WebView2Adapter` doesn't use it
  but the surface is there.
- **Notifications go through `Windows.UI.Notifications.ToastNotificationManager`.**
  The C++/WinRT shim (`swiftpwa_toast.cpp`) constructs a
  `ToastGeneric` XML payload and `Show()`s it through a notifier
  bound to the process's AUMID. We didn't take a `swift-winrt`
  dependency for this — the WinRT surface area is one notifier, one
  XML payload, one event, so a flat C ABI over the same handful of
  WinRT calls is the simpler path (same rationale as keeping
  WebView2's COM behind `swiftpwa_webview2.cpp`). When the WinRT
  path fails (Server Core without the Desktop Experience, missing
  AUMID, etc.) `SystemNotifications` falls back to a
  `Shell_NotifyIconW` balloon tip so something still shows.
- **Tray uses `Shell_NotifyIconW`, not the StatusNotifierItem spec.**
  Windows has no SNI; Microsoft has not migrated the notification
  area to a modern API. Right-click pops a `TrackPopupMenu`; left-click
  emits `TrayEvent.click` only when no menu is currently set, mirroring
  the macOS `NSStatusItem` behavior.

## Keyboard shortcuts

| Shortcut       | Action                                        |
|----------------|-----------------------------------------------|
| `Ctrl+Q`       | Quit (matches the Linux GTK binding).         |
| `Ctrl+Alt+J`   | Open WebView2 DevTools in a separate window.  |

The DevTools binding is cross-platform: `Cmd+Opt+J` on macOS via
WKWebView's `_showInspector:` SPI and `Ctrl+Alt+J` on Linux via
`webkit_web_inspector_show`.

## Known limitations (Windows-specific)

- **The portable `.exe` has no embedded icon.** `pwa.json`'s `icon`
  becomes the MSIX tile (`Square150x150Logo.png`), but the portable
  bundle's `.exe` still shows the default Windows icon in Explorer /
  the taskbar — embedding a generated `.ico` into the PE is queued
  (roadmap). macOS / iOS / Linux / Android all turn that one PNG into a
  real app icon today.
- **Action Center persistence requires a Start-menu shortcut.** The
  runtime sets a stable AppUserModelID at process start
  (`SwiftPWA.<exe-stem>`) which is enough for toasts to *show*, but
  Windows only keeps them in Action Center across reboots when the
  AUMID also matches a Start-menu `.lnk` registered with the same id.
  The MSIX path takes care of this automatically; portable bundles
  shipping outside an installer don't get persistence.
- **Notification ids are synthesized UUIDs.** The cross-platform
  `Notifications` protocol doesn't currently expose a caller-supplied
  tag, so `swift-pwa` synthesizes a UUID per send. The shim itself
  (`swiftpwa_toast_send`) takes a tag; surfacing it requires a
  protocol-level addition.
- **MSIX cross-compile not supported.** `--arch x64 | x86 | arm64`
  controls `<Identity ProcessorArchitecture>`, but the EXE itself
  comes out of `swift build` for the *host* architecture. To ship
  ARM64 + x64 packages, build twice — once on each host arch — with
  the matching `--arch` value. `Add-AppxPackage` rejects mismatched
  identity / EXE arch with "doesn't match this device".
- **MSIX post-install relaunch needs `msixIdentityName:`.** When the
  app is packaged via `swift-pwa build --target windows --package-format
  msix`, pass `msixIdentityName:` to `WindowsUpdater(installMode: .msix,
  …)` matching `pwa.json`'s `id` (with non-alphanumeric / non-dot /
  non-hyphen characters stripped — the same transform the bundler
  applies). Without it, the helper still updates the package on disk
  but skips the relaunch line and the user re-launches from Start.
- **Portable updates need a user-writable install location.**
  `WindowsUpdater(installMode: .portable)` rewrites the running EXE in
  place via a PowerShell helper. Apps installed under `C:\Program
  Files\…` without an elevation step on install will see the helper's
  `Move-Item` fail. Recommend installing portable bundles under
  `%LOCALAPPDATA%` or the user's home directory; switch to MSIX if you
  need elevation-free updates against a system-wide install. See
  [docs/auto-updates.md](auto-updates.md) for the full publishing flow.
- **`updater.windows.install_mode` field is reserved.** The
  `pwa.json` `updater.windows.install_mode` (`passive` / `silent`) is
  not consumed yet — `Add-AppxPackage` runs in its default mode.
- **`BiometricAuthPlugin` works on both packaged and unpackaged
  builds, via the `IUserConsentVerifierInterop` desktop-app
  variant.** The static
  `Windows.Security.Credentials.UI.UserConsentVerifier::RequestVerificationAsync`
  entry point assumes package identity; from a portable Win32 EXE
  the symptom is that calling `biometric.authenticate` lights up
  the camera indicator (verification *started*) but the consent
  dialog never displays — so the IAsyncOperation hangs and the JS
  side never sees a reply. The shim therefore goes through
  `IUserConsentVerifierInterop::RequestVerificationForWindowAsync`,
  passing `GetForegroundWindow()` as the parent HWND. The dialog
  appears anchored to whatever the user is looking at, which is
  the documented path for unpackaged Win32 desktop apps. The
  plugin has no link-time dependency on the WinRT projection
  toolchain; the call surface lives in
  `Sources/CWebView2Shim/swiftpwa_biometric.cpp` (C++/WinRT,
  header-only) and links the same `WindowsApp.lib` we already pull
  in for toasts. If you do ship MSIX, the static path is also
  available — but using interop unconditionally keeps the code
  paths shared between the two distribution shapes.
- **Newly-added shim headers can stay stale across `swift build`.**
  When a new `.h` lands in `Sources/CWebView2Shim/include/` (e.g.
  `swiftpwa_dialog.h`, `swiftpwa_biometric.h`), an *incremental* Swift
  build under `.build/x86_64-unknown-windows-msvc/release/` sometimes
  doesn't regenerate the clang module map and the new symbols stay
  invisible to Swift. Symptom: "no such module" or "use of unresolved
  identifier `swiftpwa_<...>`" on a build that just compiled the
  matching `.cpp` cleanly. Fix: delete the arch-qualified release
  output (a full `.build` wipe is not needed):

  ```powershell
  Remove-Item -Recurse .build\x86_64-unknown-windows-msvc\release
  ```

  This is a SwiftPM cache-invalidation quirk, not a swift-pwa bug.
  Drops out of every fresh checkout, so you'll only hit it after
  pulling new header files into an already-built tree.
- **`DialogPlugin.confirm` routes through `TaskDialogIndirect` only
  when labels are customised.** `MessageBoxW` is the simpler / more
  forgiving path; its buttons are fixed to system-localised "OK" /
  "Cancel". Whenever the JS caller passes a non-`null` `okLabel` or
  `cancelLabel`, the shim falls back to `TaskDialogIndirect` (themed,
  allows custom text), which lives in `comctl32` **v6** — and v6
  only loads when the EXE has a `Microsoft.Windows.Common-Controls`
  manifest dependency baked into its resource section. The CLI
  bundler embeds that manifest post-build via `mt.exe -manifest ...
  -outputresource:<exe>;#1` (`WindowsBundler.embedComCtl6Manifest`);
  the C++ shim cannot do it via `#pragma comment(linker,
  "/manifestdependency:...")` because `lld-link` (Swift-on-Windows
  uses clang-cl + lld-link, not MSVC's link.exe) silently drops the
  pragma at .obj-merge time. If `mt.exe` isn't on PATH (you're in a
  non-VS shell), the bundler warns and continues — `dialog.confirm`
  with custom labels falls back to plain `MessageBoxW` at runtime.
  To get the themed path: launch your build from inside a Visual
  Studio Developer Shell (the same shell that already needs to be
  active for `swift build` to find the MSVC + Windows SDK headers).
- **`.build\release` symlink warning is cosmetic.** Without
  Developer Mode (Settings → For developers → Developer Mode) or
  Administrator privileges, SwiftPM can't create the
  `.build\release` symlink to the arch-qualified output directory
  and prints

  ```text
  warning: unable to create symbolic link at .build\release: encountered an I/O error (code: 512)
  ```

  on every `swift build`. The bundler scans for the
  `*-windows-msvc\release\<Name>.exe` directly, so the warning is
  safe to ignore; enabling Developer Mode silences it but isn't
  required.
- **The Evergreen Bootstrapper trusts the WebView2 registry.** The
  `--bootstrap-webview2` install path works end-to-end on a fresh
  machine where the runtime was never installed. On a *partially
  broken* WebView2 install (binaries missing but registry entries
  still present — typically the result of a manual delete or a
  failed uninstall),
  `MicrosoftEdgeWebview2Setup.exe` reads the registry, decides the
  runtime is already installed, and exits without writing anything.
  The user is left with the same "WebView2 Runtime not found"
  diagnostic. Recovery is to run an Edge repair (Settings → Apps
  → Microsoft Edge → Modify → Repair) — the WebView2 Runtime is
  shipped as part of Edge's redistributable on stable Win11. We
  don't try to detect this state from the runtime side because
  there's no signal beyond the same `COREWEBVIEW2_E_RUNTIME_NOT_FOUND`
  HRESULT a clean-uninstalled box returns.
- **`swift test` doesn't work on Windows; tests run via a dedicated
  executable.** SwiftPM's swift-testing discovery build plugin emits
  0-byte stubs for every suite on Windows (verified on Swift 6.1.2 and
  6.3.1, x64 and arm64), so the test bundle finds zero tests at
  runtime and `swift test` exits 1 with no stderr. `--list-tests` /
  `--dump-tests-json` hang on the same path, which was the source of
  the `error: abnormal(312)` CI signature when `--filter` was used.
  `--disable-xctest` doesn't help — the swift-testing pass also finds
  zero tests because the discovery sections aren't populated.
  Windows test coverage therefore lives in
  [Sources/SwiftPWAWindowsTestRunner/main.swift](../Sources/SwiftPWAWindowsTestRunner/main.swift),
  a plain executable that re-expresses the `WindowsUpdater` assertions
  with a small harness. Run it with `swift run SwiftPWAWindowsTestRunner`;
  CI does the same. The other suites (`SwiftPWACoreTests` etc.) get
  compile-checked on Windows via `swift build --build-tests` but can't
  be *run* until SwiftPM's Windows discovery is fixed upstream.
- **Content packs: extraction/creation are `tar.exe`, served mounts use
  `WebResourceRequested`.** `fs.extractZip` / `fs.listZip` / `fs.createZip`
  work on Windows, but **not** via ZIPFoundation — its `CZLib` shim uses
  `#import <zlib.h>`, which clang-cl rejects, and Windows ships no
  system zlib. The same `ZIPExtractor` type therefore shells to
  `tar.exe` (libarchive's bsdtar, bundled in Windows 10 1803+),
  enforcing the traversal / symlink / zip-bomb guards via a pre-extract
  `tar -tvf` listing pass. `fs.createZip` runs `tar --format zip
  --options zip:compression=store|deflate`. One degradation: bsdtar's
  listing doesn't expose per-entry *compressed* size, so the
  `maxCompressionRatio` guard is a no-op on Windows (the
  `maxUncompressedBytes` / `maxEntries` guards still apply). The `tar.exe`
  paths aren't exercised by CI (SwiftPM test discovery is broken on
  Windows, so the job builds but doesn't run tests). For **serving**,
  `SetVirtualHostNameToFolderMapping`
  maps a whole host, not a subpath, so `ctx.serveDirectory(_:at:)`
  mounts are served via a `WebResourceRequested` interception filtered
  to the bundle origin (the bundle itself keeps its native virtual-host
  mapping; only requests under a served prefix are intercepted), with
  range support implemented in the C++ shim.
- **On-device llama.cpp is x64-only on Windows.** The prebuilt
  `llama.lib` (see §4) is published for x64; an arm64-Windows build
  (Snapdragon X) isn't produced yet, so `ai.local_llama` on a
  `--target windows` build from an arm64 host errors at the CLI's
  artifact-resolve step. GPU acceleration needs a Vulkan 1.2+ driver / ICD
  at runtime — without one the model falls back to CPU. CI's `windows-llama`
  job is a **link check only** (no GPU on the runner, and `swift test` can't
  run on Windows); real GPU verification happens on the x64 dev box. Linking
  also needs the Vulkan SDK's `vulkan-1.lib` at build time, beyond the
  driver's runtime `vulkan-1.dll`.
