# swift-pwa

Build your app as a web frontend — HTML/CSS/JS, or React/Vue/Svelte — and ship it as a genuine native app on macOS, iOS, Linux, Windows, and Android, all from one Swift package. `swift-pwa` wraps each platform's own system webview in a thin native shell, so there's no bundled browser and downloads stay small (5–15 MB). It's Tauri or Wails for the Swift world, with on-device AI built in.

> **Status:** [`v0.8.13`](https://github.com/tophatch/swift-pwa/releases/tag/v0.8.13) is the current release. macOS 15+, iOS 18+, Linux (GTK3 / GTK4), Windows 11 (WebView2), and Android (API 28+) are all first-class — one Swift package, one JS API, one CLI, five platforms from the same source.
>
> This is young, fast-moving software (pre-1.0, under heavy active development) — expect rapid iteration and the occasional breaking change before 1.0. **Feedback, [issues](https://github.com/tophatch/swift-pwa/issues), and contributions are very welcome** — real-world usage reports are especially valuable at this stage.

Highlights: a [feature matrix](#feature-matrix) of native plugins (files, dialogs, secrets, notifications, subprocess, and more), [built-in on-device & cloud AI](#on-device--cloud-ai) on every platform, and per-platform [setup docs](docs/). See [`CHANGELOG.md`](CHANGELOG.md) for the full release-by-release history.

## Why

If you want to ship a web frontend as a real native app on every platform, today's options each make you give something up:

- **Electron** ships an 80 MB Chromium with every download, in JavaScript. Desktop only.
- **Tauri** is small, fast, and reaches mobile — but the native shell is Rust, a steep learning curve if it isn't already your language.
- **Wails** is small and fast in Go — but desktop only.
- **Hand-rolled WKWebView** locks you to Apple, and you're rebuilding the JS↔Swift bridge, the bundler, and the multi-window plumbing yourself.
- **SwiftUI WebView** is single-platform and ships no bridge or bundling story.

`swift-pwa` matches Tauri on the fundamentals — a system webview, a 5–15 MB bundle, and all five of macOS, iOS, Linux, Windows, and Android from one source — and then wins on three fronts:

- **You build in web; the native shell is a thin slice of Swift.** The whole frontend is the web stack you already know — plain HTML/CSS/JS or React/Vue/Svelte — and the wrapper is a small Swift package you rarely touch, shipped everywhere by one CLI (`.app`, `.ipa`, `.AppImage`, a portable Windows `.exe`, MSIX, and an Android project → APK / AAB) with one JS API (`__SWIFT_PWA__.invoke()`). Tauri and Wails wrap a web frontend too, but their shell is Rust or Go — a second systems language to pick up (or hire for) just to get a native window. Swift is a gentle on-ramp if you've ever opened an Xcode project, and for a team already on Apple platforms it's the stack, packages, and models you use every day, now driving Linux, Windows, and Android as well.
- **The native capabilities a real app needs are built in.** A web page can't touch the filesystem, the system tray, or a fingerprint reader — swift-pwa hands them to your JS through opt-in plugins: local files and native Open/Save dialogs, secrets in the OS keychain (Keychain / Keystore / DPAPI / libsecret), biometric auth (Touch/Face ID, Windows Hello, Android fingerprint), clipboard, tray icons, native notifications, subprocesses, server-push events, and a CORS-free HTTP client — each adapted to every platform's conventions and App Store friendly (it bundles to store-ready `.ipa`, `.aab`, and MSIX artifacts, using the system webview and sanctioned native APIs). See the [feature matrix](#feature-matrix) for what lands where.
- **AI is a framework feature, not an integration you assemble.** The whole [`ai.*` API](#on-device--cloud-ai) — on-device text, image generation / editing / segmentation, and cloud and LAN providers — ships with the framework, cross-platform. In Electron / Tauri / Wails, local inference is DIY: bundle a sidecar, stand up a Python backend, or reach for a third-party plugin.

|                   | **swift-pwa**       | Tauri    | Wails    | Electron |
|-------------------|---------------------|----------|----------|----------|
| Host language     | Swift               | Rust     | Go       | Node.js  |
| Webview           | System              | System   | System   | Bundled  |
| Bundle size       | ~5-15 MB            | ~5-15 MB | ~5-15 MB | ~80+ MB  |
| macOS             | Yes                 | Yes      | Yes      | Yes      |
| Linux             | Yes                 | Yes      | Yes      | Yes      |
| Windows           | Yes                 | Yes      | Yes      | Yes      |
| iOS               | Yes                 | Yes      | No       | No       |
| Android           | Yes                 | Yes      | No       | No       |
| On-device AI      | Built-in (`ai.*`)   | DIY      | DIY      | DIY      |

## Quickstart

Grab a release binary and scaffold a project:

```bash
# Pick the asset for your platform from
# https://github.com/tophatch/swift-pwa/releases/latest
# (macOS arm64 example):
curl -L https://github.com/tophatch/swift-pwa/releases/latest/download/swift-pwa-macos-arm64 \
    -o /usr/local/bin/swift-pwa
chmod +x /usr/local/bin/swift-pwa

swift-pwa init MyApp
cd MyApp
```

Other available assets: `swift-pwa-macos-x86_64`, `swift-pwa-linux-x86_64`, `swift-pwa-windows-x86_64.exe` (added to the release matrix in v0.3). See [docs/windows-setup.md](docs/windows-setup.md) for the Windows toolchain.

Once it's on your `PATH`, update in place anytime with **`swift-pwa self-update`** (macOS / Linux) — it resolves the latest release, verifies the download, and installs it with an atomic rename, which sidesteps a macOS code-signing-cache quirk that makes a plain `cp` overwrite crash with `Killed: 9`. Pin a version with `--version vX.Y.Z`.

Or build the CLI from source (works on every platform, including Windows on ARM64):

```bash
git clone https://github.com/tophatch/swift-pwa
swift run --package-path swift-pwa swift-pwa init MyApp
cd MyApp
```

You get a self-contained SwiftPM project:

```text
MyApp/
├── Package.swift                      # depends on SwiftPWA
├── pwa.json                           # source of truth — generates Info.plist / .desktop / bundle metadata
├── Sources/MyApp/App.swift            # @main entry point; creates a window pointing at web/
├── .github/workflows/release.yml      # push a tag → build every desktop platform in CI
└── web/
    └── index.html                     # your frontend's entry point
```

That `release.yml` means you can ship cross-platform from any machine: `git tag v1.0.0 && git push --tags` builds macOS, Linux, and Windows in GitHub Actions and attaches them to a Release — no local Swift / MSVC / GTK toolchains needed. (iOS / Android are included as opt-in stubs since they need signing / a cross-compile SDK.) Opt out with `init --no-ci-workflow`; add it to an existing project later with `swift-pwa generate-ci`.

`build` operates on this scaffold — it runs `swift build` against `Package.swift`, so `pwa.json` + `web/` on their own aren't buildable. Already have a web app? `init` adopts it automatically — run it from a directory that already has a `web/` or `pwa.json` and it adds only the native shell (`Package.swift` + `Sources/`), leaves your `web/` untouched, and merges any missing fields into an existing `pwa.json` rather than overwriting it:

```bash
cd my-existing-web-app   # has web/ (or a hand-written pwa.json) already
swift-pwa init MyApp     # detects the existing app and adopts it in place
```

Pass `--in-place` to force this for a frontend in a non-standard layout (e.g. a custom `dist/` with no `pwa.json` yet).

### Where the web source goes

Anything in `web/` is your PWA frontend — plain HTML/CSS/JS, or the build output of React/Vue/Svelte/whatever. The bundler copies the directory verbatim into the app and serves it through a custom `pwa://localhost/` scheme so relative URLs resolve cleanly without needing a local dev server.

To point at a different directory (e.g. `dist/` from a Vite build), edit the `web` section of `pwa.json`:

```json
"web": { "directory": "dist", "entry": "index.html" }
```

### Configuring `pwa.json`

`pwa.json` is the single source of truth. `Info.plist`, `.desktop`, bundle identifiers, window dimensions, and icon assets are all generated from it.

```json
{
    "id": "com.example.myapp",
    "name": "My App",
    "version": "0.1.0",
    "description": "An optional one-liner.",
    "icon": "icon.png",
    "web": { "directory": "web", "entry": "index.html" },
    "window": {
        "title": "My App",
        "width": 1024,
        "height": 768,
        "resizable": true,
        "fullscreen": false,
        "background_color": "#F4F7F5",
        "remember_state": true
    },
    "macos": {
        "bundle_identifier": "com.example.myapp",
        "category": "public.app-category.productivity",
        "minimum_system_version": "15.0",
        "copyright": "© 2026 Acme Corp."
    },
    "ios": {
        "bundle_identifier": "com.example.myapp",
        "minimum_system_version": "18.0",
        "device_family": [1, 2]
    },
    "linux": {
        "desktop_categories": ["Utility"]
    }
}
```

Required keys: `id`, `name`, `version`, `web`, `window`. The `macos` / `ios` / `linux` sections are optional — omit any platform you don't ship to. `icon` should be a single 1024×1024 PNG — that one file becomes the app icon on every platform: macOS `.icns`, the iOS `AppIcon` (compiled via `actool`), the Android launcher icon (`res/mipmap/ic_launcher.png` + manifest wiring), the Linux AppImage icon, and the Windows portable `.exe` icon (embedded into the PE via `UpdateResource`). `category` on macOS is the `LSApplicationCategoryType` UTI shown in the App Store / Finder. `description` and `macos.copyright` populate the **About** panel (the description becomes the body text, the copyright shows under the version).

**`name` is the human-facing label** — the `.app` filename, `CFBundleName` / `CFBundleDisplayName`, the `.desktop` `Name=` — and may contain spaces (`"My App"`). The built binary, by contrast, is named after the SwiftPM target in `Package.swift`, which **can't** contain spaces. You don't have to reconcile the two: the bundlers discover the real target name from the package itself (via `swift package describe`), so `"name": "My App"` just works even though the target is `MyApp`. The optional **`executable_name`** is an override for the rare case where discovery is ambiguous — chiefly a package with **more than one executable product**; set it to the target you want bundled. (`linux.executable_name` still overrides this for the Linux backend specifically.)

**`window` is build-time metadata, not the runtime config.** The generated `Sources/<name>/App.swift` builds the window from a `WindowConfig` literal, and *that* is what the running app uses. `init` seeds the literal from `pwa.json`'s `window` block, but editing `pwa.json`'s `window.*` afterwards has **no runtime effect** — change the window in `App.swift` (or keep the two in sync by hand). The fields here drive bundle metadata and the initial scaffold only.

**`window.remember_state`** persists the window's size — and, where the platform allows, position — across launches, restoring it next time (on by default for apps scaffolded with `init`). It maps to `WindowConfig.rememberState` in `App.swift`; geometry is saved to a `window-state.json` in the per-app data directory. **Desktop only:** macOS / GTK3 / Windows restore both size and position; GTK4 / Wayland restore size only (the compositor owns placement); iOS / Android windows are full-screen, so it's a no-op. A multi-window app sets a distinct `WindowConfig.stateKey` per window so their frames are tracked separately.

**Optional `build.prebuild`** — a command run from the project root *before* `web/` is staged into the bundle, on every `swift-pwa build` (and so on every cloud release that calls it, no hand-maintained "regenerate before tagging" ritual). Use it for a codegen / asset step that produces part of `web/` — an esbuild / Tailwind pass, a sprite-atlas packer, a generated index. A non-zero exit aborts the build, so a half-generated `web/` never ships. It runs through the platform shell (`/bin/sh -c`, `cmd /c` on Windows); skip it for fast local iteration with `build --skip-prebuild`. If it needs a toolchain (Node, etc.), add a setup step to the generated workflow's jobs.

```json
"build": { "prebuild": "node scripts/build-index.mjs" }
```

**Optional `build.postbuild`** — the symmetric *after-bundling* hook: a command run once the platform artifact exists, with its absolute path in `SWIFT_PWA_ARTIFACT` (and the target in `SWIFT_PWA_TARGET`). Use it to patch the generated bundle without wrapping the whole `swift-pwa build` — e.g. a `PlistBuddy` tweak, extra signing, a checksum. Non-zero exit fails the build; `--skip-postbuild` bypasses it.

```json
"build": { "postbuild": "./scripts/sign-extra.sh \"$SWIFT_PWA_ARTIFACT\"" }
```

**Optional `macos.info_plist` / `ios.info_plist`** — arbitrary keys merged into the generated `Info.plist` (after swift-pwa's own, so they override on collision). The escape hatch for anything the schema doesn't model: App Transport Security, usage strings, custom URL schemes. Use the exact Info.plist key names; nested objects/arrays work.

```json
"macos": { "info_plist": { "NSAppTransportSecurity": { "NSAllowsLocalNetworking": true } } }
```

**Optional `build.serve`** — serve extra directories on the bundle origin under an app-chosen path prefix, so page JS references runtime-imported content (a downloaded "content pack" of images / video) with an origin-relative URL — `videoEl.src = "/packs/<id>/clip.webm"` — that works unchanged on every backend, streamed with HTTP range requests. On desktop the equivalent is `ctx.serveDirectory(_:at:)` at `configure()` time; Android needs the mount declared here (its asset loader is built before any Swift runs). See [docs/swift-api.md](docs/swift-api.md#serving-extra-directories-content-packs).

```json
"build": { "serve": [ { "mount": "/packs", "from": "data/packs" } ] }
```

### Develop with live reload

```bash
swift-pwa dev                      # serves web/ with live reload, launches the app
```

`swift-pwa dev` serves your `web/` directory itself, injects a live-reload client, and refreshes the app whenever you save a file — no JS framework or external server needed (macOS / Linux; on Windows pass `--server`). Already using a bundler with its own hot-reload (Vite, etc.)? Point at it instead: `swift-pwa dev --server http://localhost:5173`. (The generated `App.swift` loads the dev URL when `PWA_DEV_SERVER` is set, falling back to the bundled assets in a real build.)

The built-in server binds a **fixed port** (`4321`) so the dev origin is stable across launches — that's what lets OPFS / localStorage / IndexedDB **persist between runs** (an OS-assigned port would mint a fresh origin each launch and wipe storage). Override with `--port <n>`, or `--port 0` for the old ephemeral behavior.

### Build and run

```bash
swift-pwa doctor                   # check this machine has the toolchains a build needs
swift run swift-pwa build          # --target defaults to the host (macos/linux/windows)
open ./build/MyApp.app
```

`swift-pwa doctor [--target <platform>]` reports, with a copy-paste fix for each gap, whether the tools a target needs are installed (Xcode for iOS, `linuxdeploy` for AppImages, the Android NDK, etc.) — so a missing prerequisite is a friendly message up front rather than a cryptic mid-build failure. `swift-pwa build` also runs these required-tool checks as a quiet preflight: it stays silent on a healthy machine and, only if something's missing, prints one line pointing you at `doctor` before the compile starts.

`--target` defaults to the desktop platform you're building on, so you can omit it for a host build; pass it explicitly for cross-targets (`--target ios`, `--target android`) or to bundle for another desktop OS.

For codesigning, device deployment, and Linux GTK setup, see [Platform setup](#platform-setup).

## Feature matrix

`Yes` = first-class. `Partial` = works with documented caveats (footnoted; per-platform detail in the matching [docs/&lt;platform&gt;-setup.md](docs/)). `—` = not applicable.

| Capability                    | macOS                   | iOS                          | Linux GTK3                 | Linux GTK4              | Windows                  | Android                  |
| ----------------------------- | :---------------------: | :--------------------------: | :------------------------: | :---------------------: | :----------------------: | :----------------------: |
| Webview                       | WKWebView               | WKWebView                    | WebKitGTK 4.1              | WebKitGTK 6.0           | WebView2 (Edge)          | android.webkit.WebView   |
| Min OS / runtime              | macOS 15                | iOS 18                       | Ubuntu 22.04+ / Fedora 36+ | GTK 4.10+               | Win10 21H2+ + WebView2   | API 28 (Android 9)       |
| JS↔Swift bridge               | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| Multi-window                  | Yes                     | Partial¹                     | Yes                        | Yes                     | Yes                      | —⁷                       |
| DevTools (`Cmd/Ctrl+Alt+J`)   | Yes                     | —                            | Yes                        | Yes                     | Yes                      | Remote⁸                  |
| Per-Monitor V2 DPI            | —                       | —                            | —                          | —                       | Yes                      | —                        |
| `WindowPlugin`                | Yes                     | Yes                          | Yes                        | Partial²                | Yes                      | Partial⁷                 |
| `AppPlugin` (`app.quit` …)    | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| `ClipboardPlugin`             | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| `EventsPlugin` (server push)  | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| `DialogPlugin`                | Yes                     | Partial³                     | Yes                        | Yes⁴                    | Yes                      | Partial¹⁰                |
| `FsPlugin`                    | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| `ProcessPlugin` (subprocess)  | Yes                     | —¹²                          | Yes                        | Yes                     | Yes                      | —¹²                      |
| `NetPlugin` (`net.*` HTTP)    | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| `SecretsPlugin` (`secrets.*`) | Keychain                | Keychain                     | libsecret¹³                | libsecret¹³             | DPAPI                    | Keystore                 |
| `AIPlugin` — text¹⁴           | Foundation Models       | Foundation Models            | llama.cpp                  | llama.cpp               | Phi Silica¹⁵             | Gemini Nano              |
| `AIPlugin` — images¹⁶         | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| `VisionPlugin`¹⁷              | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| `AIWorkflowPlugin`¹⁸          | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| `TrayPlugin`                  | Yes                     | —                            | Yes                        | —                       | Yes                      | —                        |
| `NotificationsPlugin`         | Yes⁵                    | Yes⁵                         | Yes                        | Yes                     | Yes                      | Yes                      |
| `BiometricAuthPlugin`         | Touch / Face ID         | Touch / Face / Optic ID      | —                          | —                       | Windows Hello            | Fingerprint / Face¹¹     |
| `UpdaterPlugin` (runtime)     | Yes⁶                    | Untested⁶                    | Yes⁶                       | Yes⁶                    | Yes⁶                     | Yes (PackageInstaller)   |
| `swift-pwa updater` CLI       | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| Bundler artifact              | `.app`                  | `.app` / `.ipa`              | `.AppImage`                | `.AppImage`             | Portable / MSIX          | Gradle project → APK/AAB |
| Code-signing pass-through     | `codesign`              | `codesign`                   | —                          | —                       | `signtool`               | Gradle `signingConfigs`⁹ |

1. iOS UIScene single scene polished, multi-scene scaffolded.
2. `Window.position()` / `setPosition` / `.didMove` are no-ops on GTK4 (Wayland refuses to give apps their own position).
3. iOS has no system *save panel*, so `dialog.saveFile` (which hands back a path for the app to write) is a no-op there. Use `dialog.exportFile` instead — it presents `UIDocumentPickerViewController` and does the write, giving iOS a real save/share UX (added v0.7.9; the same command works on every platform).
4. GTK4 dialogs require GTK 4.10+ (`GtkAlertDialog` / `GtkFileDialog`).
5. Apple notifications require a bundled, signed `.app` (`UNUserNotificationCenter` rejects unsigned processes).
6. **macOS**, **Linux** (AppImage), and **Windows** (portable) are verified end-to-end — a real check→download→Ed25519-verify→atomic-swap→relaunch cycle on each (macOS ad-hoc + codesigned; Linux including the cross-filesystem EXDEV copy-then-rename fallback; Windows portable `Move-Item` swap). Android's `PackageInstaller` path is exercised. **Windows MSIX** is compile-verified — its `Add-AppxPackage` install path is preview (full E2E needs a signed package + a trusted cert + sideloading). **iOS**'s `itms-services://` path needs an enterprise cert. The publishing CLI is fully tested. Full breakdown: [docs/auto-updates.md](docs/auto-updates.md).
7. Most `Window` shape APIs (`setSize`, `setPosition`, `minimize`, etc.) are no-ops — the platform owns those decisions; multi-window spawns a new Activity per `createWindow`. Detail: [docs/android-setup.md](docs/android-setup.md) §6.
8. Android `WebView` has no programmatic DevTools window; debug via `chrome://inspect` on a connected host. `webView.openDevTools()` logs an `adb`-friendly hint.
9. Driven by `pwa.json`'s `android.signing` (or `--sign` / `--android-key-alias` CLI overrides) with passwords from environment variables. Full wiring + CI pattern: [docs/android-setup.md](docs/android-setup.md) §7.
10. Android `dialog.openFile` / `saveFile` / `openDirectory` use the Storage Access Framework and return `content://` URIs rather than filesystem paths; `Fs` routes those URIs through `ContentResolver` transparently. Detail: [docs/android-setup.md](docs/android-setup.md) §6.1.
11. Android's `BiometricManager` doesn't distinguish fingerprint / face / iris — `BiometricKind` is `.unknown` when available. Gate JS on `available`, not `kind`.
12. `ProcessPlugin` needs to spawn OS processes; the iOS / Android sandboxes forbid it, so `process.*` reports `E_UNIMPLEMENTED` there. Desktop only.
13. `SecretsPlugin` stores: Apple **Keychain**, Android **Keystore** (`EncryptedSharedPreferences`), Windows **DPAPI** (user scope), Linux **Secret Service** (libsecret → GNOME Keyring / KWallet). Two runtime needs: Windows DPAPI needs an interactive user session (a network/SSH logon lacks the master key); Linux needs a running Secret Service (a desktop keyring — headless servers have none, where calls return `E_SECRETS`). Registered without a store it falls back to `NoneSecretStore` (every call `E_SECRETS`). Detail: [docs/secrets.md](docs/secrets.md).
14. `AIPlugin` is opt-in (`ctx.use(AIPlugin(…))`). Text uses each platform's built-in model; portable **llama.cpp** (`ai.local_llama`) is also available on macOS / iOS / Linux / Windows (Metal on Apple, Vulkan GPU on Linux + Windows x64, CPU on Windows arm64) — not on Android. See [docs/ai-plugin.md](docs/ai-plugin.md).
15. Windows **Phi Silica** (`ai.phi_silica`) needs an MSIX build **and** a Microsoft Limited-Access-Feature token; the unpackaged fallback is llama.cpp. See [docs/ai-plugin.md](docs/ai-plugin.md).
16. `ai.generateImage` (text→image / img2img / inpaint): on-device via the shared **ONNX Runtime** tier (`ai.local_onnx_runtime` — Stable Diffusion + LaMa), optionally GPU-accelerated on Linux / Windows desktop (`ai.onnx_gpu` — DirectML / CUDA); plus cloud / LAN providers (Imagen, ComfyUI, any REST image API) over `net.*`. Real-weights verification is documented on macOS / desktop + Android. See [docs/remote-ai.md](docs/remote-ai.md).
17. On-device promptable segmentation (MobileSAM) on the same ONNX Runtime tier (`ai.local_onnx_runtime`); the `ai.onnx_gpu` desktop-GPU tier applies here too.
18. `AIWorkflowPlugin` imports and runs remote workflows (e.g. ComfyUI) with live per-step progress, over `net.*` (WebSocket progress via `URLSessionWebSocketTask`, or an OkHttp RPC on Android).

The full per-plugin command surface lives in [docs/javascript-api.md](docs/javascript-api.md) (JS side) and [docs/swift-api.md](docs/swift-api.md) (Swift side). Per-platform setup, codesigning, and the long tail of known limitations live in the [Platform setup](#platform-setup) docs.

## On-device & cloud AI

On-device and cloud AI is a first-class part of the framework, not a bring-your-own integration — all of it reachable from the web app through one `ai.*` JS API:

- **Text generation on every platform** — the built-in OS model (Apple Foundation Models, Android Gemini Nano, Windows Phi Silica) *or* portable llama.cpp (GPU-accelerated via Metal on Apple and Vulkan on Linux + Windows x64; CPU on Windows arm64), behind one flag.
- **On-device image models** — a shared ONNX Runtime tier powers promptable *segmentation*, *inpainting* / editing, and *text→image* generation (SD-Turbo plus the commercially-usable LCM_Dreamshaper, both matched to a diffusers reference), all through a purpose-agnostic `ai.generateImage`. An optional desktop GPU tier (Windows DirectML / Linux CUDA) accelerates them, with transparent CPU fallback.
- **Cloud and LAN image generation, no rebuild** — point a running app at any JSON image API from a descriptor, with presets for Imagen, Gemini image ("nano banana"), OpenAI, and Qwen. API keys live in the OS keychain (Keychain / Keystore / DPAPI / libsecret), never in JS.
- **Run imported AI workflows from the web app** — `ai.run` / `ai.describeInputs` import a ComfyUI graph (or drive Imagen / on-device models) and run it with live per-step progress, cancel, and job recovery — the graph and the connection travel in each call.

Tap-to-segment, tap-to-erase, prompt-to-image, and a live model switcher are all demoed in `Examples/CritterFacts`. Deep dives live in [docs/remote-ai.md](docs/remote-ai.md), [docs/ai-plugin.md](docs/ai-plugin.md), and the [on-device AI tutorial](docs/tutorials/on-device-ai.md).

## API at a glance

```js
// JS — full reference: docs/javascript-api.md
await __SWIFT_PWA__.invoke('window.setTitle', { title: 'Hello' });
const unsub = __SWIFT_PWA__.subscribe('window.subscribe', {}, (e) => { /* ... */ });

// Server-push events (Swift → JS, all windows) and subprocesses (desktop):
const off = __SWIFT_PWA__.on('library:changed', (payload) => { /* ... */ });
__SWIFT_PWA__.subscribe('process.stream', { command: 'ffmpeg', args: [/* … */] }, (f) => { /* ... */ });

// Device memory — exact/uncapped RAM (beats navigator.deviceMemory, works on iOS):
const { availableBytes } = await __SWIFT_PWA__.invoke('system.memory');
__SWIFT_PWA__.on('system.memoryPressure', ({ level }) => shrinkCaches(level));
```

```swift
// Swift — full reference: docs/swift-api.md
import SwiftPWA

let runtime = try SwiftPWA.runtime()
try runtime.run { ctx in
    ctx.use(DialogPlugin(SystemDialog()))   // opt-in plugins
    ctx.use(FsPlugin(SystemFs()))
    _ = try ctx.createWindow(.init(
        title: "Hello",
        size: .init(width: 1024, height: 768),
        content: .bundled((Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("web"))
    ))
}
```

## Tutorials

Copy-paste-friendly, Swift-optional walkthroughs for common features live in [docs/tutorials/](docs/tutorials/):

- [Hello, World — your first app](docs/tutorials/hello-world.md) — from `init` to a running native app with live reload; understand every generated file. Start here.
- [Talking to the native side](docs/tutorials/talking-to-the-native-side.md) — the JS↔Swift bridge (`invoke` / `subscribe` / `on`) and how to register your own native command.
- [Wrapping an existing React / Vite app](docs/tutorials/wrapping-a-react-or-vite-app.md) — adopt a bundler-built app in place, point at your `dist/`, keep HMR, and handle SPA routing.
- [Saving and loading files (Export / Import)](docs/tutorials/saving-and-loading-files.md) — native Save / Open dialogs over `dialog.*` + `fs.*`, with an automatic browser fallback so one codebase runs everywhere.
- [Opening files with your app (file associations)](docs/tutorials/opening-files-with-your-app.md) — be the app the OS launches for a file type; receive it on the `app.openFile` channel.
- [On-device AI](docs/tutorials/on-device-ai.md) — wire up the `ai.*` API for local text and image generation, from `ai.info` and model download through streaming output.
- [Calling a cloud API with a stored key](docs/tutorials/calling-a-cloud-api.md) — secure key storage (`secrets.*`) + native CORS-free HTTP (`net.*`), keeping the key out of your web code.
- [Locking your app with biometrics](docs/tutorials/locking-with-biometrics.md) — Touch/Face ID, Windows Hello, Android fingerprint via `biometric.*`, with graceful fallback.
- [Making it feel native](docs/tutorials/making-it-feel-native.md) — window controls, native notifications, and a system-tray icon, with per-platform notes.
- [Multi-window apps](docs/tutorials/multi-window-apps.md) — open and target multiple windows and coordinate between them over `events.*`.
- [Running a command-line tool](docs/tutorials/running-a-command-line-tool.md) — spawn and drive a subprocess (`process.*`) with live output and automatic teardown (desktop-only).
- [Importing content packs](docs/tutorials/importing-content-packs.md) — import a large `.zip` of media at runtime and serve it to the page off disk, with native extraction and re-export.
- [Shipping your app (all platforms)](docs/tutorials/shipping-your-app.md) — build, sign, and distribute on macOS, iOS, Linux, Windows, and Android, plus one-tag cloud releases and an auto-update heads-up.
- [Auto-updates](docs/tutorials/auto-updates.md) — make your app update itself: publish a signed manifest, wire the runtime plugin, drive check/download/install from JS, plus background auto-check and a mandatory-update kill-switch.

## Bundling

```bash
swift run swift-pwa build --target macos                              # → MyApp.app
swift run swift-pwa build --target macos --sign "Developer ID Application: Acme"
swift run swift-pwa build --target ios --simulator                    # unsigned .app for sim
swift run swift-pwa build --target linux                              # → MyApp-x86_64.AppImage
swift run swift-pwa build --target windows                            # → portable folder bundle
swift run swift-pwa build --target windows --package-format msix --arch arm64 --sign <thumbprint>
swift run swift-pwa build --target windows --bootstrap-webview2       # bundle the Evergreen Bootstrapper
swift run swift-pwa build --target android                            # → MyApp-android/ Gradle project
swift run swift-pwa build --target android --cross-compile-android --android-abis arm64-v8a,x86_64
```

`pwa.json` is the source of truth — `Info.plist`, `.desktop`, `AppxManifest.xml`, and icon assets all generate from it. Per-target setup (toolchain, codesign, device install) lives under [Platform setup](#platform-setup). If `pwa.json` declares a [`build.prebuild`](#configuring-pwajson) command, every `build` runs it first.

The `swift-pwa updater` subcommand publishes auto-update manifests (`keygen`, `sign`, `manifest`) — see [docs/auto-updates.md](docs/auto-updates.md). To update the CLI itself, run `swift-pwa self-update`.

## Roadmap

Shipped work lives in [`CHANGELOG.md`](CHANGELOG.md) — a per-release breakdown from the on-device AI tiers back through the Android backend and the CLI developer-experience passes. What's next, in priority order:

1. **Auto-updates.** The publishing side (`swift-pwa updater keygen` / `sign` / `manifest`, Ed25519, the manifest format) is solid; the runtime install path needs work:
   - **Verify + harden the desktop runtime updater.** **macOS, Linux (AppImage), and Windows (portable) are now verified** end-to-end — a real check→download→Ed25519-verify→atomic-swap→relaunch cycle on each, which hardened four staging/cleanup gaps along the way (macOS ad-hoc + codesigned; Linux including the cross-filesystem EXDEV fallback; Windows portable `Move-Item` swap). Remaining: **Windows MSIX** full E2E (compile-verified; `Add-AppxPackage` install needs a signed package + trusted cert + sideloading) and **iOS** (`itms-services://`, needs an enterprise cert), plus broader integration coverage. Unblocks the two below. Context: [docs/auto-updates.md](docs/auto-updates.md).
   - **Delta updates** — ship binary diffs instead of full artifacts to cut download size; extend the publishing CLI to emit per-version patches and the runtime to apply them.
2. **GTK4 tray.** `TrayPlugin` is the last plugin-parity gap — `Yes` on GTK3, `—` on GTK4 (matrix). GTK4 dropped `GtkStatusIcon`; needs a `StatusNotifierItem` (libayatana-appindicator / SNI D-Bus) implementation behind the existing `SystemTray` protocol so the cross-platform API is unchanged. Document any Wayland caveats in [docs/linux-setup.md](docs/linux-setup.md).
3. **On-device AI: audio generation backend.** The `ai.*` contract is complete and the **text** and **image** backends have shipped — text on every OS (Apple Foundation Models / Android Gemini Nano / Windows Phi Silica + portable **llama.cpp**), and on-device **image** generation + editing via the ONNX Runtime tier (Stable Diffusion text→image, LaMa inpainting; v0.8.3–0.8.6). Still open: a real **audio** (`ai.generateAudio` / TTS) *generation* backend — the contract and a CoreML/MLX implementation guide exist, but no backend ships yet — plus exercising Windows Phi Silica generation end-to-end once a Microsoft LAF token lands. Context: [docs/ai-plugin.md](docs/ai-plugin.md).
4. **Platform audio (capture / playback).** Native microphone capture and audio playback / device routing behind a plugin — lower-latency and more capable than the WebView's `getUserMedia` / `MediaRecorder`, which already cover the in-page cases (including feeding recordings to the `ai.*` audio input). Pairs with the on-device AI audio backend.
5. **Bidirectional bridge sessions (live streaming).** The bridge is request → server-stream-out today; a duplex/session primitive (client can push frames into an open subscription) would unlock real-time use cases — continuous-mic speech evaluation, collaborative streams — that the current `subscribe` can't express. A bridge-layer capability, broader than any one plugin.
6. **Typed JS↔Swift codegen layer** — generate typed client bindings (TS + Swift) for `invoke` / `subscribe` from the registered command set, replacing the stringly-typed envelope at the call site.
7. **Crisp multi-size Windows `.exe` icon** — the portable `.exe` already embeds the `pwa.json` icon (via `UpdateResource`), but as a single source image the shell downscales it; a WIC resize to ship dedicated 16/32/48/256 px slots would sharpen the small sizes.
8. **Built-in live reload on Windows** — the `swift-pwa dev` server is POSIX-only today (macOS / Linux); Windows still needs `--server <url>`.
9. **Homebrew tap** — `brew install tophatch/tap/swift-pwa` as the idiomatic macOS / Linux install + upgrade story. `swift-pwa self-update` already covers the no-brew and Windows cases.

Per-platform "Known limitations" sections in each [docs/&lt;platform&gt;-setup.md](docs/) cover the long tail.

## Platform setup

Per-platform walkthroughs (toolchain, build, codesign, device install, known caveats):

- **macOS** — [docs/macos-setup.md](docs/macos-setup.md): Xcode 26+, `.app` bundling, Developer ID signing, notarization.
- **iOS** — [docs/ios-setup.md](docs/ios-setup.md): Simulator runtime install, `.app` install via `simctl`, device run via Xcode.
- **Linux** — [docs/linux-setup.md](docs/linux-setup.md): Ubuntu 24.04+ + Swift 6.0, GTK3 + WebKitGTK 4.1 by default or GTK4 + WebKitGTK 6.0 via `SWIFT_PWA_GTK4=1`, AppImage builds.
- **Windows** — [docs/windows-setup.md](docs/windows-setup.md): Swift 6 on Windows, Visual Studio Build Tools, the WebView2 SDK / static loader, and the portable `.exe` bundler.
- **Android** — [docs/android-setup.md](docs/android-setup.md): Swift 6.2.0 + swift-android-sdk 6.2, NDK r27d, JDK 17 + AGP 8.5, the `@_cdecl` entry-point boilerplate, and the Gradle scaffold the `swift-pwa build --target android` bundler emits. [docs/android-on-device-testing.md](docs/android-on-device-testing.md) covers driving the page from the host over `adb forward` + Chrome DevTools Protocol.

## Contributing

Contributions, bug reports, and feedback are all very welcome — swift-pwa is young, actively developed software, and real-world usage reports (what worked, what broke, what's missing) are some of the most useful things you can send. Open an [issue](https://github.com/tophatch/swift-pwa/issues) for a bug or an idea, or a PR for a fix or feature. See [`CHANGELOG.md`](CHANGELOG.md) for what shipped, what's in `Unreleased`, and the running list of release notes.

```bash
swift test                                     # unit + WebKit integration on macOS
SWIFT_PWA_LINUX_GUI=1 swift test               # GTK integration tests on Linux
```

Before tagging a release, walk the manual cases in [docs/manual-test-cases.md](docs/manual-test-cases.md) — they cover the OS-level install machinery, on-device installer flows, and visual smoothness checks that the unit suite can't reach.

## License

Apache-2.0. See [`LICENSE`](LICENSE).
