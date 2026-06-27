# swift-pwa

A Swift-native, thin-client PWA wrapper around system webviews — Tauri/Wails for the Swift world.

> **Status:** [`v0.7.1`](https://github.com/tophatch/swift-pwa/releases/tag/v0.7.1) is the current release — macOS 15+, iOS 18+, Linux (GTK3 / GTK4), Windows 11 (WebView2), and Android (API 28+) are all first-class. See the [feature matrix](#feature-matrix), the per-platform [setup docs](docs/), and [`CHANGELOG.md`](CHANGELOG.md).

## Why

If you write Swift, today's options for shipping a thin-client app are uncomfortable:

- **Electron** ships an 80 MB Chromium with every download, in JavaScript. Desktop only.
- **Tauri** is small, fast, and reaches mobile — but you're writing Rust.
- **Wails** is small and fast in Go — but desktop only.
- **Hand-rolled WKWebView** locks you to Apple, and you're rebuilding the JS↔Swift bridge, the bundler, and the multi-window plumbing yourself.
- **SwiftUI WebView** is single-platform and ships no bridge or bundling story.

`swift-pwa` is the option for Swift shops: one Swift package, one JS API (`__SWIFT_PWA__.invoke()`), one CLI. The same source produces `.app`, `.ipa`, `.AppImage`, portable Windows `.exe`, MSIX, and an Android Gradle project that builds to APK / AAB.

|                  | **swift-pwa**  | Tauri    | Wails    | Electron |
|------------------|----------------|----------|----------|----------|
| Host language    | Swift          | Rust     | Go       | Node.js  |
| Webview          | System         | System   | System   | Bundled  |
| Bundle size      | ~5-15 MB       | ~5-15 MB | ~5-15 MB | ~80+ MB  |
| macOS            | Yes            | Yes      | Yes      | Yes      |
| Linux            | Yes            | Yes      | Yes      | Yes      |
| Windows          | Yes            | Yes      | Yes      | Yes      |
| iOS              | Yes            | Yes      | No       | No       |
| Android          | Yes            | Yes      | No       | No       |

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
        "background_color": "#F4F7F5"
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

Required keys: `id`, `name`, `version`, `web`, `window`. The `macos` / `ios` / `linux` sections are optional — omit any platform you don't ship to. `icon` should be a single 1024×1024 PNG — that one file becomes the app icon on every platform: macOS `.icns`, the iOS `AppIcon` (compiled via `actool`), the Android launcher icon (`res/mipmap/ic_launcher.png` + manifest wiring), and the Linux AppImage icon. (A Windows `.exe` icon isn't generated yet.) `category` on macOS is the `LSApplicationCategoryType` UTI shown in the App Store / Finder. `description` and `macos.copyright` populate the **About** panel (the description becomes the body text, the copyright shows under the version).

**`name` is the human-facing label** — the `.app` filename, `CFBundleName` / `CFBundleDisplayName`, the `.desktop` `Name=` — and may contain spaces (`"My App"`). The built binary, by contrast, is named after the SwiftPM target in `Package.swift`, which **can't** contain spaces. You don't have to reconcile the two: the bundlers discover the real target name from the package itself (via `swift package describe`), so `"name": "My App"` just works even though the target is `MyApp`. The optional **`executable_name`** is an override for the rare case where discovery is ambiguous — chiefly a package with **more than one executable product**; set it to the target you want bundled. (`linux.executable_name` still overrides this for the Linux backend specifically.)

**`window` is build-time metadata, not the runtime config.** The generated `Sources/<name>/App.swift` builds the window from a `WindowConfig` literal, and *that* is what the running app uses. `init` seeds the literal from `pwa.json`'s `window` block, but editing `pwa.json`'s `window.*` afterwards has **no runtime effect** — change the window in `App.swift` (or keep the two in sync by hand). The fields here drive bundle metadata and the initial scaffold only.

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

`swift-pwa doctor [--target <platform>]` reports, with a copy-paste fix for each gap, whether the tools a target needs are installed (Xcode for iOS, `linuxdeploy` for AppImages, the Android NDK, etc.) — so a missing prerequisite is a friendly message up front rather than a cryptic mid-build failure.

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
| `DialogPlugin`                | Yes                     | Partial³                     | Yes                        | Yes⁴                    | Yes                      | Partial¹⁰                |
| `FsPlugin`                    | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| `TrayPlugin`                  | Yes                     | —                            | Yes                        | —                       | Yes                      | —                        |
| `NotificationsPlugin`         | Yes⁵                    | Yes⁵                         | Yes                        | Yes                     | Yes                      | Yes                      |
| `BiometricAuthPlugin`         | Touch / Face ID         | Touch / Face / Optic ID      | —                          | —                       | Windows Hello            | Fingerprint / Face¹¹     |
| `UpdaterPlugin` (runtime)     | Untested⁶               | Untested⁶                    | Untested⁶                  | Untested⁶               | Untested⁶                | Yes (PackageInstaller)   |
| `swift-pwa updater` CLI       | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| Bundler artifact              | `.app`                  | `.app` / `.ipa`              | `.AppImage`                | `.AppImage`             | Portable / MSIX          | Gradle project → APK/AAB |
| Code-signing pass-through     | `codesign`              | `codesign`                   | —                          | —                       | `signtool`               | Gradle `signingConfigs`⁹ |

1. iOS UIScene single scene polished, multi-scene scaffolded.
2. `Window.position()` / `setPosition` / `.didMove` are no-ops on GTK4 (Wayland refuses to give apps their own position).
3. `dialog.saveFile` is a stub — iOS has no system save panel.
4. GTK4 dialogs require GTK 4.10+ (`GtkAlertDialog` / `GtkFileDialog`).
5. Apple notifications require a bundled, signed `.app` (`UNUserNotificationCenter` rejects unsigned processes).
6. Runtime backends are unit-tested but the per-OS install hand-off is preview until [docs/manual-test-cases.md](docs/manual-test-cases.md) is walked. The publishing CLI is fully tested. Full breakdown: [docs/auto-updates.md](docs/auto-updates.md).
7. Most `Window` shape APIs (`setSize`, `setPosition`, `minimize`, etc.) are no-ops — the platform owns those decisions; multi-window spawns a new Activity per `createWindow`. Detail: [docs/android-setup.md](docs/android-setup.md) §6.
8. Android `WebView` has no programmatic DevTools window; debug via `chrome://inspect` on a connected host. `webView.openDevTools()` logs an `adb`-friendly hint.
9. Driven by `pwa.json`'s `android.signing` (or `--sign` / `--android-key-alias` CLI overrides) with passwords from environment variables. Full wiring + CI pattern: [docs/android-setup.md](docs/android-setup.md) §7.
10. Android `dialog.openFile` / `saveFile` / `openDirectory` use the Storage Access Framework and return `content://` URIs rather than filesystem paths; `Fs` routes those URIs through `ContentResolver` transparently. Detail: [docs/android-setup.md](docs/android-setup.md) §6.1.
11. Android's `BiometricManager` doesn't distinguish fingerprint / face / iris — `BiometricKind` is `.unknown` when available. Gate JS on `available`, not `kind`.

The full per-plugin command surface lives in [docs/javascript-api.md](docs/javascript-api.md) (JS side) and [docs/swift-api.md](docs/swift-api.md) (Swift side). Per-platform setup, codesigning, and the long tail of known limitations live in the [Platform setup](#platform-setup) docs.

## API at a glance

```js
// JS — full reference: docs/javascript-api.md
await __SWIFT_PWA__.invoke('window.setTitle', { title: 'Hello' });
const unsub = __SWIFT_PWA__.subscribe('window.subscribe', {}, (e) => { /* ... */ });
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

- [Saving and loading files (Export / Import)](docs/tutorials/saving-and-loading-files.md) — native Save / Open dialogs over `dialog.*` + `fs.*`, with an automatic browser fallback so one codebase runs everywhere.

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

- **v0.5** (released) — Android backend at desktop parity: Swift target, JNI shim, Kotlin / Gradle scaffold, full plugin set including streaming `updater.install` events, `setFullscreen` via `WindowInsetsControllerCompat`, multi-window via Activity-per-window, and transparent SAF `content://` URI handling in `Fs`. CI runs the cross-compile + `assembleDebug` pipeline on every push. Wiring lives in [docs/android-setup.md](docs/android-setup.md); the on-device test loop in [docs/android-on-device-testing.md](docs/android-on-device-testing.md).
- **v0.5.1 / v0.5.2** (released) — CLI developer-experience pass for adopting an existing web app: `pwa.json` `executable_name` (now auto-discovered from the package, rarely needed), `swift-pwa init` in-place adoption (auto-detected), host-default `--target`, `App.swift` seeded from the manifest `window` block, actionable `build` preflight errors, and a [docs/tutorials/](docs/tutorials/) series.
- **v0.6.0** (released) — "friendliness wave" making "package a web app cross-platform" require minimal setup: `swift-pwa init` scaffolds a **GitHub Actions release workflow** (tag → all desktop platforms built in the cloud; `swift-pwa generate-ci` for existing projects); one `pwa.json` `icon` PNG now becomes the **iOS + Android app icon** too (not just macOS); **`swift-pwa doctor`** checks per-target toolchain prerequisites; `build --target macos --notarize` **automates notarization** (submit → wait → staple); and **`swift-pwa dev`** runs a built-in live-reload server.
- **v0.6.1 / v0.6.2** (released) — a second ease-of-use pass: an **`AppPlugin`** (`app.quit` / `app.name` / `app.version`, so a Quit button needs no Swift); **`doctor` flags a generated `App.swift` that lags the CLI** (the shell is version-stamped); a single `SWIFT_PWA_CLI_VERSION` in the generated workflow; a corrected JS API reference; a **`build.prebuild`** hook in `pwa.json` for codegen / asset steps that produce part of `web/`; and **`swift-pwa self-update`** to update the CLI in place.
- **v0.6.3** (released) — **runtime content packs**: import a large `.zip` of media at runtime and serve it to the page. **`ctx.serveDirectory(_:at:)`** serves a writable directory on the bundle origin under an app-chosen prefix (`/packs/…`), range-aware on every backend so big `<video>` streams off disk; **`fs.extractZip`** / **`fs.listZip`** (+ a streaming progress subscription) extract natively, path-to-path — bytes never cross the bridge — with traversal / symlink / zip-bomb guards. All five platforms (ZIPFoundation on Apple+Linux, `tar.exe` on Windows, `java.util.zip`-via-JNI on Android), device-verified on Android. See [docs/swift-api.md](docs/swift-api.md#serving-extra-directories-content-packs).
- **v0.6.4** (released) — **`fs.createZip`**, the symmetric counterpart to `fs.extractZip`, for in-app pack authoring / re-export: zip a folder path-to-path (bytes never cross the bridge), with `compression: "stored"` (default — pack media is already compressed) or `"deflate"`, and a streaming progress subscription. The everyday small-pack case still zips in-browser as a `Blob`; `createZip` is the giant-file escape hatch (a multi-GB media folder, or re-exporting an installed pack whose source is a `dataDir` folder). Same backends as extraction. See the [content-packs tutorial](docs/tutorials/importing-content-packs.md). Also hardens CI: the Linux test step now tolerates a swift-corelibs process-exit hang (retry-on-timeout, without masking real failures).
- **v0.6.5** (released) — a developer-experience pass from adopter feedback: **`macos.info_plist` / `ios.info_plist`** passthrough merges arbitrary keys (ATS, usage strings, URL schemes) into the generated `Info.plist`; **`build.postbuild`** runs an after-bundling step with the artifact path in `SWIFT_PWA_ARTIFACT`; **`swift-pwa dev`** binds a **fixed port** so OPFS / localStorage / IndexedDB persist across launches; **`build`/`doctor` warn on Android `package_id` ↔ `@_cdecl` drift** (the silent `UnsatisfiedLinkError` footgun); a prebuilt CLI no longer crashes resolving its resource bundle (`Bundle.module` trap fixed); a manifest **`web.entry`** is now honored by the generated native window; and the **`safe.bareRepository`** git warning is silenced for the CLI's child processes.
- **v0.7.1** (released) — the portable on-device **llama.cpp** backend (`SwiftPWALlama` / `LlamaBackend`): runs a GGUF model on-device (Metal-accelerated), text + token streaming + GBNF-constrained JSON, shipped as a prebuilt xcframework consumed via an env-gated `.binaryTarget` and turned on per app with `ai.local_llama` in `pwa.json`. **Apple first** (Linux/Windows packaging — with Vulkan for the GPU path — to follow). Plus iOS signing fixes from adopter feedback: device builds no longer fail without a development team (the xcodebuild phase is built unsigned; swift-pwa signs post-assembly), and a new `--team` convenience that fills in the signing identity + an installed provisioning profile.
- **v0.7.0** (released) — the **`ai.*` plugin**: on-device LLM inference behind the bridge (`ai.info` / `ai.generate` / `ai.generateJSON` / streaming, plus multimodal vision + audio input, `ai.generateImage`, and `ai.generateAudio`/TTS), with the first real backend — **Apple Foundation Models** (native schema-constrained JSON) — and a resumable, checksum-pinned `ai.ensureModel` model downloader. Plus an adopter-DX round: iOS **universal (iPad)** default, **`window.background_color`** (native surface colour before first paint, every backend), and **installable iOS device builds** (`--provisioning-profile` / `--entitlements`, fail-fast, `doctor --target ios`). Also folds in the embedded Gradle wrapper + the `BSDTarListParser` Linux test fix.

Next up, in priority order:

1. **Verify + harden the desktop runtime updater.** The `UpdaterPlugin` runtime is marked **Untested** on all five desktop platforms (see the feature-matrix footnote 6) — only Android's `PackageInstaller` path is exercised end-to-end. The publishing side (`swift-pwa updater keygen` / `sign` / `manifest`, Ed25519, the manifest format) is solid; what's unverified is each backend's `Updater.installAndRelaunch` (download → signature-verify → atomic swap → relaunch). Goal: drive a real check→download→install→relaunch on macOS / Windows / Linux (AppImage), flip those matrix cells to `Yes`, and add integration coverage. This unblocks the two updater items below. Context: [docs/auto-updates.md](docs/auto-updates.md).
2. **GTK4 tray.** `TrayPlugin` is the last plugin-parity gap — `Yes` on GTK3, `—` on GTK4 (matrix). GTK4 dropped `GtkStatusIcon`; needs a `StatusNotifierItem` (libayatana-appindicator / SNI D-Bus) implementation behind the existing `SystemTray` protocol so the cross-platform API is unchanged. Document any Wayland caveats in [docs/linux-setup.md](docs/linux-setup.md).
3. **On-device AI backends.** The `ai.*` plugin contract shipped (0.7) — `ai.info` / `ai.generate` / `ai.generateJSON` / streaming, plus multimodal **vision + audio input**, **text→image generation** (`ai.generateImage`), and **text→audio / TTS** (`ai.generateAudio`), schema-valid JSON on any backend. Two real backends are now implemented and verified end-to-end on-device: **Apple Foundation Models** (`SwiftPWAFoundationModels`) and the portable **llama.cpp** backend (`SwiftPWALlama` — runs a GGUF model, Metal-accelerated, GBNF-constrained JSON; opt in with `ai.local_llama` in `pwa.json`), which is **Apple-first** with Linux/Windows packaging next. After that: Android Gemini Nano, Windows Phi Silica, and the image/audio backends (Image Playground / Stable Diffusion; Speech / Whisper / TTS), each in its own optional target like the zip backends. Context: [docs/ai-plugin.md](docs/ai-plugin.md).
4. **Platform audio (capture / playback).** Native microphone capture and audio playback / device routing behind a plugin — lower-latency and more capable than the WebView's `getUserMedia` / `MediaRecorder`, which already cover the in-page cases (including feeding recordings to the `ai.*` audio input). Pairs with the on-device AI audio backends.
5. **Bidirectional bridge sessions (live streaming).** The bridge is request → server-stream-out today; a duplex/session primitive (client can push frames into an open subscription) would unlock real-time use cases — continuous-mic speech evaluation, collaborative streams — that the current `subscribe` can't express. A bridge-layer capability, broader than any one plugin.
6. **Delta updates** — ship binary diffs instead of full artifacts to cut update download size. Builds on (1); extend the publishing CLI to emit per-version patches and the runtime to apply them.
7. **Mandatory-update kill-switch (`min_supported_version`)** — let a manifest force-upgrade clients below a floor. Called out as a known gap in [docs/auto-updates.md](docs/auto-updates.md); also builds on (1).
8. **Typed JS↔Swift codegen layer** — generate typed client bindings (TS + Swift) for `invoke` / `subscribe` from the registered command set, replacing the stringly-typed envelope at the call site.
9. **Windows `.exe` icon** — embed an `.ico` generated from the `pwa.json` icon (the one platform the icon pipeline doesn't yet cover).
10. **Built-in live reload on Windows** — the `swift-pwa dev` server is POSIX-only today (macOS / Linux); Windows still needs `--server <url>`.
11. **Homebrew tap** — `brew install tophatch/tap/swift-pwa` as the idiomatic macOS / Linux install + upgrade story. `swift-pwa self-update` already covers the no-brew and Windows cases.

Per-platform "Known limitations" sections in each [docs/&lt;platform&gt;-setup.md](docs/) cover the long tail. [`CHANGELOG.md`](CHANGELOG.md) has the per-release breakdown.

## Platform setup

Per-platform walkthroughs (toolchain, build, codesign, device install, known caveats):

- **macOS** — [docs/macos-setup.md](docs/macos-setup.md): Xcode 26+, `.app` bundling, Developer ID signing, notarization.
- **iOS** — [docs/ios-setup.md](docs/ios-setup.md): Simulator runtime install, `.app` install via `simctl`, device run via Xcode.
- **Linux** — [docs/linux-setup.md](docs/linux-setup.md): Ubuntu 24.04+ + Swift 6.0, GTK3 + WebKitGTK 4.1 by default or GTK4 + WebKitGTK 6.0 via `SWIFT_PWA_GTK4=1`, AppImage builds.
- **Windows** — [docs/windows-setup.md](docs/windows-setup.md): Swift 6 on Windows, Visual Studio Build Tools, the WebView2 SDK / static loader, and the portable `.exe` bundler.
- **Android** — [docs/android-setup.md](docs/android-setup.md): Swift 6.2.0 + swift-android-sdk 6.2, NDK r27d, JDK 17 + AGP 8.5, the `@_cdecl` entry-point boilerplate, and the Gradle scaffold the `swift-pwa build --target android` bundler emits. [docs/android-on-device-testing.md](docs/android-on-device-testing.md) covers driving the page from the host over `adb forward` + Chrome DevTools Protocol.

## Contributing

PRs welcome. See [`CHANGELOG.md`](CHANGELOG.md) for what shipped, what's in `Unreleased`, and the running list of release notes.

```bash
swift test                                     # unit + WebKit integration on macOS
SWIFT_PWA_LINUX_GUI=1 swift test               # GTK integration tests on Linux
```

Before tagging a release, walk the manual cases in [docs/manual-test-cases.md](docs/manual-test-cases.md) — they cover the OS-level install machinery, on-device installer flows, and visual smoothness checks that the unit suite can't reach.

## License

Apache-2.0. See [`LICENSE`](LICENSE).
