# swift-pwa

A Swift-native, thin-client PWA wrapper around system webviews — Tauri/Wails for the Swift world.

> **Status:** [`v0.8.1`](https://github.com/tophatch/swift-pwa/releases/tag/v0.8.1) is the current release — macOS 15+, iOS 18+, Linux (GTK3 / GTK4), Windows 11 (WebView2), and Android (API 28+) are all first-class, with **built-in on-device AI on every platform**: the OS platform model (Apple Foundation Models, Android Gemini Nano, Windows Phi Silica) *and* portable GPU/CPU-accelerated llama.cpp (Apple Metal, Linux + Windows x64 Vulkan, Windows arm64). **The on-device ONNX Runtime tier — promptable image segmentation via `ai.vision.*` (`MobileSAMBackend`) — runs on all five platforms**, with a checksum-pinned downloadable-model tier (`ai.vision.ensureModel`) and a `pwa.json` opt-in (`ai.local_onnx_runtime`) that stages everything into the build automatically; **0.8.1** completes it with automatic "segment everything" mask generation (`ai.vision.segmentAll`), a device-capability `benchmark`, and the Linux + Windows desktop backends. Tap-to-segment demoed in `Examples/CritterFacts`. See the [feature matrix](#feature-matrix), the per-platform [setup docs](docs/), and [`CHANGELOG.md`](CHANGELOG.md).

## Why

If you write Swift, today's options for shipping a thin-client app are uncomfortable:

- **Electron** ships an 80 MB Chromium with every download, in JavaScript. Desktop only.
- **Tauri** is small, fast, and reaches mobile — but you're writing Rust.
- **Wails** is small and fast in Go — but desktop only.
- **Hand-rolled WKWebView** locks you to Apple, and you're rebuilding the JS↔Swift bridge, the bundler, and the multi-window plumbing yourself.
- **SwiftUI WebView** is single-platform and ships no bridge or bundling story.

`swift-pwa` is the option for Swift shops: one Swift package, one JS API (`__SWIFT_PWA__.invoke()`), one CLI. The same source produces `.app`, `.ipa`, `.AppImage`, portable Windows `.exe`, MSIX, and an Android Gradle project that builds to APK / AAB.

And **on-device AI is built in, not bring-your-own.** A single `ai.*` JS API (`ai.generate` / `ai.generateStream` / schema-constrained `ai.generateJSON`, plus a resumable, checksum-pinned model downloader) is backed by real on-device engines — **Apple Foundation Models** on Apple hardware and **GPU-accelerated llama.cpp** (Metal on Apple, **Vulkan** on Linux + Windows, one artifact covering NVIDIA / AMD / Intel) — opt-in with a single `ai.local_llama` flag. In Electron / Tauri / Wails, local inference is a DIY integration: bundle a sidecar (Ollama, `candle`), stand up a Python + llama.cpp backend, or reach for a third-party plugin. Here it's a first-class, cross-platform part of the framework.

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

Required keys: `id`, `name`, `version`, `web`, `window`. The `macos` / `ios` / `linux` sections are optional — omit any platform you don't ship to. `icon` should be a single 1024×1024 PNG — that one file becomes the app icon on every platform: macOS `.icns`, the iOS `AppIcon` (compiled via `actool`), the Android launcher icon (`res/mipmap/ic_launcher.png` + manifest wiring), and the Linux AppImage icon. (A Windows `.exe` icon isn't generated yet.) `category` on macOS is the `LSApplicationCategoryType` UTI shown in the App Store / Finder. `description` and `macos.copyright` populate the **About** panel (the description becomes the body text, the copyright shows under the version).

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
12. `ProcessPlugin` needs to spawn OS processes; the iOS / Android sandboxes forbid it, so `process.*` reports `E_UNIMPLEMENTED` there. Desktop only.

The full per-plugin command surface lives in [docs/javascript-api.md](docs/javascript-api.md) (JS side) and [docs/swift-api.md](docs/swift-api.md) (Swift side). Per-platform setup, codesigning, and the long tail of known limitations live in the [Platform setup](#platform-setup) docs.

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
- **v0.8.1** (released) — **completes the `ai.vision.*` segmentation tier to full cross-platform parity.** Three fast-follows on `MobileSAMBackend`: **automatic mask generation** (`ai.vision.segmentAll` / `segmentAllStream`, `autoMask: true`) — a grid-of-prompts sweep + NMS returning every distinct object as its own mask, streaming per-cell progress; a device-capability **`ai.vision.benchmark`** (synthetic encode/decode/AMG timing → a coarse `high`/`mid`/`low` `deviceClass`); and the **Linux x86_64 + Windows x64 desktop backends** (CPU ONNX Runtime — image decode via a vendored stb_image + a pure-Swift resize since there's no CoreGraphics there; the shared lib staged into the AppImage / next to the `.exe` automatically), so segmentation now runs on **all five** platforms. Verified end-to-end against real weights on macOS, a Linux box, and a Windows box. (Linux needs Swift 6.1+ for the segmentation target.) Context: [docs/proposals/segmentation-plugin.md](docs/proposals/segmentation-plugin.md).
- **v0.8.0** (released) — **the on-device ONNX Runtime tier, with promptable image segmentation as its first consumer.** A new **`ai.vision.*`** plugin (`SegmentationBackend` / `VisionPlugin`) does tap-to-segment (SAM-family): `ai.vision.info` / `openSession` (encode once) / `segment` (cheap decode) / `closeSession`. The shipping backend — **`MobileSAMBackend`** (`SwiftPWASegmentation`, **Apple + Android** in 0.8.0; desktop in 0.8.1) — runs MobileSAM's encoder + decoder as ONNX Runtime sessions, verified against real weights on-device (Galaxy Z Fold7, IoU ~0.99). Turn it on with **`ai.local_onnx_runtime: true`** in `pwa.json`: `swift-pwa build` links the runtime and, on Android, stages the per-ABI `libonnxruntime.so` into the APK automatically. **`ai.vision.ensureModel`** downloads the ~60 MB weights on first run (resumable + checksum-pinned, from the `mobilesam-vendor` release; on Android through the platform HTTP stack, since swift-corelibs `URLSession` can't do TLS there). **`Examples/CritterFacts`** gains a tap-to-segment demo page. Context: [docs/proposals/segmentation-plugin.md](docs/proposals/segmentation-plugin.md).
- **v0.7.10** (released) — **device memory to JS**, because `navigator.deviceMemory` is quantized, capped at 8 GB, and absent in WKWebView. `__platform.info` gains **`physicalMemoryBytes`** (exact, uncapped, present on iOS) and **`appMemoryLimitBytes`**; a new auto-installed **`system.*`** plugin adds **`system.memory`** (a live `{ physicalBytes, availableBytes, appLimitBytes, lowMemory }` read from each OS's native API) and a **`system.memoryPressure`** event (`warning`/`critical`) so the OS can tell the app to shed caches before it kills the process — wired via `DispatchSource` on iOS/macOS and `onTrimMemory` on Android (Linux/Windows have no portable pressure signal). Device-verified on a Tab S10+. Bundles the **window state memory** work (`window.remember_state`) and an Android cross-compile stale-cache guard that prevents a layout-skew startup crash. See [docs/javascript-api.md](docs/javascript-api.md#system).
- **v0.7.9** (released) — rounding out the file surface. **`dialog.exportFile`** is a content-first "save this": the web app hands over the bytes (`dataBase64`) or a source `path` and the backend runs the platform's save/export UI *and does the write*, returning the destination — which is what finally makes **save work on iOS** (`UIDocumentPickerViewController(forExporting:)`; `dialog.saveFile` had always been a no-op there). Same command everywhere (save panel + write on desktop, SAF create-document + write on Android). Also **completes `app.openFile` on Android** — OS "Open With" / share (`VIEW` / `SEND`) intents now reach the `app.openFile` channel (declare types via **`android.document_types`**), matching macOS/iOS/Linux/Windows — and **fixes Linux `window.isFullscreen()`**, which reported `false` even after `setFullscreen(true)` on both GTK backends. See [docs/javascript-api.md](docs/javascript-api.md#dialog).
- **v0.7.8** (released) — two adopter-feedback items. **OS "Open With" → JS**: the runtime now forwards a file the OS opens the app with (Finder / Explorer "Open With", `open -a`, file double-click) onto an **`app.openFile`** event channel — `__SWIFT_PWA__.on('app.openFile', ({ paths }) => …)` — closing the runtime half of file associations (declaring a type already worked; the file was dropped). Captured via `NSApplicationDelegate` (macOS), scene URL contexts incl. cold launch (iOS), and launch argv (Linux/Windows); emitted **retained** so a file that *launched* the app isn't lost before the WebView subscribes. And an **Android DayNight fix**: `window.background_color` used to pin the activity to a Light theme, so `prefers-color-scheme: dark` never matched inside the WebView — the generated theme is now `DayNight` with `values` / `values-night` variants (and `background_color` accepts a `{ light, dark }` pair). See [docs/javascript-api.md](docs/javascript-api.md#appopenfile--os-open-with--launch-with-file) and [docs/android-setup.md](docs/android-setup.md#windowbackground_color).
- **v0.7.7** (released) — two adopter-feedback items. **`dialog.openDirectory` multi-select**: a `multiple` flag (mirroring `dialog.openFile`) lets one invocation register several folders — the result is now `{ paths, path }`, with `path` (the first selection) kept so existing callers don't break. Native on every desktop backend (macOS/iOS, GTK3/GTK4, Windows); Android's SAF tree picker grants one directory per launch, so `multiple` is desktop-only there. And **per-request reference-audio voice cloning** in the `ai.*` audio contract: `AIGenerateAudioRequest` gains `referenceAudio` (inline or on-disk) + `referenceText`, with an `AICapabilities.voiceCloning` flag — the reference rides on the request, so a user-switchable voice changes per call with no backend re-init (both fields optional; existing backends ignore them). See [docs/javascript-api.md](docs/javascript-api.md) and [docs/ai-plugin.md](docs/ai-plugin.md).
- **v0.7.6** (released) — two capabilities from adopter feedback, both native. A **subprocess plugin** (`process.*`, opt-in, desktop-only) launches/streams an external child process — `process.stream` (base64 stdout/stderr → `exit`), `process.write` (stdin), `process.kill` — with **guaranteed teardown**: the child's lifetime is bound to its stream subscription, so unsubscribe or window-close kills it (no orphans). And a **server-push event bus** (`events.*`, auto-installed): `ctx.emit(channel, payload)` fans out to `__SWIFT_PWA__.on(channel, cb)` subscribers in **every** window, with a retained-latest-value option for late subscribers — replacing the hand-rolled "bus stream" every multi-window app was reinventing. Plus a worked guide for implementing a native on-device audio (TTS) `AIBackend` against CoreML/MLX. See [docs/process-plugin.md](docs/process-plugin.md) and [docs/swift-api.md](docs/swift-api.md#server-push-events).
- **v0.7.5** (released) — a fix: **`window.background_color` now applies on Android.** It was the one backend that parsed the field and never used it, so an Android build flashed the stock white launch window and kept a default-light status bar. The `--target android` bundler now emits a `Theme.SwiftPWA` (window background + status / navigation bar colour, with system-bar icon luminance picked from the colour) and fills the WebView surface — matching the iOS launch-screen treatment. Device-verified on a Galaxy Z Fold7.
- **v0.7.4** (released) — **the platform-built-in AI tier, on every OS.** The `ai.*` plugin's tier-1 built-in is now wired on each platform that ships one: **Apple Foundation Models** (Apple), **Android Gemini Nano** via ML Kit GenAI / AICore (`ai.gemini_nano`, verified on a Galaxy Z Fold7), and **Windows Phi Silica** via the Windows App SDK (`ai.phi_silica`, verified `available`/Ready on a Copilot+ NPU — *generation* needs an MSIX build + a Microsoft Limited-Access-Feature token). The portable **llama.cpp** backend also reaches **Windows arm64** (Snapdragon X Copilot+) on CPU — the unpackaged, no-token on-device fallback there; an experimental Adreno-Vulkan build path is gated behind `LLAMA_WIN_ARM64_VULKAN` (the Adreno's Vulkan compute is still upstream-buggy, so it's not shipped). One example — **`Examples/CritterFacts`** — now exercises both tiers across platforms.
- **v0.7.3** (released) — **on-device AI reaches every desktop OS.** The llama.cpp backend now runs on **Windows x64** and **Linux x86_64**, GPU-accelerated via **Vulkan** (one artifact for NVIDIA / AMD / Intel), alongside Apple's Metal — so `ai.local_llama` is GPU-accelerated across macOS / Linux / Windows from one codebase (verified generating tokens on an RTX 5080 and an AMD Radeon 780M). Off-Apple linking uses a `.systemLibrary` + an env-set linker search path (`LIBRARY_PATH` / `LIB`), never `unsafeFlags`. Plus a Windows distribution-polish pass driven by running the new **`Examples/CritterFacts`** demo (local-LLM fun facts, streamed on the GPU): **`build --target windows --single-file`** ships a portable app as one self-contained `.exe` (`web/` embedded in the binary, served from memory); the bundled exe is a clean GUI app (no stray console window) whose WebView2 profile lives in `%LOCALAPPDATA%` instead of polluting the bundle; and a class of diagnostic-stderr crashes on console-less GUI apps is fixed.
- **v0.7.2** (released) — Android content-pack import from adopter feedback: **`fs.extractZip` / `fs.listZip` accept a `content://` SAF source** (a user-picked archive extracts off-bridge via the `ContentResolver` → `ZipInputStream`, no base64 materialize), and the **prebuilt single-file CLI builds Android again** (`bridge.js` is embedded in the CLI rather than read from `SwiftPWACore`'s resource bundle, which a single-file binary can't resolve). Plus a cross-compile docs fix for staging the Swift runtime libs.
- **v0.7.1** (released) — the portable on-device **llama.cpp** backend (`SwiftPWALlama` / `LlamaBackend`): runs a GGUF model on-device (Metal-accelerated), text + token streaming + GBNF-constrained JSON, shipped as a prebuilt xcframework consumed via an env-gated `.binaryTarget` and turned on per app with `ai.local_llama` in `pwa.json`. **Apple first** (Linux/Windows packaging — with Vulkan for the GPU path — to follow). Plus iOS signing fixes from adopter feedback: device builds no longer fail without a development team (the xcodebuild phase is built unsigned; swift-pwa signs post-assembly), and a new `--team` convenience that fills in the signing identity + an installed provisioning profile.
- **v0.7.0** (released) — the **`ai.*` plugin**: on-device LLM inference behind the bridge (`ai.info` / `ai.generate` / `ai.generateJSON` / streaming, plus multimodal vision + audio input, `ai.generateImage`, and `ai.generateAudio`/TTS), with the first real backend — **Apple Foundation Models** (native schema-constrained JSON) — and a resumable, checksum-pinned `ai.ensureModel` model downloader. Plus an adopter-DX round: iOS **universal (iPad)** default, **`window.background_color`** (native surface colour before first paint, every backend), and **installable iOS device builds** (`--provisioning-profile` / `--entitlements`, fail-fast, `doctor --target ios`). Also folds in the embedded Gradle wrapper + the `BSDTarListParser` Linux test fix.

Next up, in priority order:

1. **Verify + harden the desktop runtime updater.** The `UpdaterPlugin` runtime is marked **Untested** on all five desktop platforms (see the feature-matrix footnote 6) — only Android's `PackageInstaller` path is exercised end-to-end. The publishing side (`swift-pwa updater keygen` / `sign` / `manifest`, Ed25519, the manifest format) is solid; what's unverified is each backend's `Updater.installAndRelaunch` (download → signature-verify → atomic swap → relaunch). Goal: drive a real check→download→install→relaunch on macOS / Windows / Linux (AppImage), flip those matrix cells to `Yes`, and add integration coverage. This unblocks the two updater items below. Context: [docs/auto-updates.md](docs/auto-updates.md).
2. **GTK4 tray.** `TrayPlugin` is the last plugin-parity gap — `Yes` on GTK3, `—` on GTK4 (matrix). GTK4 dropped `GtkStatusIcon`; needs a `StatusNotifierItem` (libayatana-appindicator / SNI D-Bus) implementation behind the existing `SystemTray` protocol so the cross-platform API is unchanged. Document any Wayland caveats in [docs/linux-setup.md](docs/linux-setup.md).
3. **On-device AI: image + audio backends.** The `ai.*` contract (text + vision/audio input, `ai.generateImage`, `ai.generateAudio` / TTS, schema-valid JSON) and all the **text** backends shipped through 0.7.4 — platform built-ins on **every** OS (Apple Foundation Models / Android Gemini Nano / Windows Phi Silica) plus portable **llama.cpp** (Apple Metal, Linux + Windows x64 Vulkan, Windows arm64 CPU). Next: the **image** (Image Playground / Stable Diffusion) and **audio** (Speech / Whisper / TTS) *generation* backends, each in its own optional target like the zip backends — plus exercising Windows Phi Silica generation end-to-end once a Microsoft LAF token lands. Context: [docs/ai-plugin.md](docs/ai-plugin.md).
4. **Platform audio (capture / playback).** Native microphone capture and audio playback / device routing behind a plugin — lower-latency and more capable than the WebView's `getUserMedia` / `MediaRecorder`, which already cover the in-page cases (including feeding recordings to the `ai.*` audio input). Pairs with the on-device AI audio backends.
5. **Bidirectional bridge sessions (live streaming).** The bridge is request → server-stream-out today; a duplex/session primitive (client can push frames into an open subscription) would unlock real-time use cases — continuous-mic speech evaluation, collaborative streams — that the current `subscribe` can't express. A bridge-layer capability, broader than any one plugin.
6. **Delta updates** — ship binary diffs instead of full artifacts to cut update download size. Builds on (1); extend the publishing CLI to emit per-version patches and the runtime to apply them.

On-device segmentation (`ai.vision.*`) reached full cross-platform parity in **v0.8.1** (above). The one remaining fast-follow — a **GPU execution-provider desktop build** (CUDA / DirectML, vs. today's CPU ONNX Runtime on Linux/Windows) — is flagged for **v0.8.2**.
8. **Mandatory-update kill-switch (`min_supported_version`)** — let a manifest force-upgrade clients below a floor. Called out as a known gap in [docs/auto-updates.md](docs/auto-updates.md); also builds on (1).
9. **Typed JS↔Swift codegen layer** — generate typed client bindings (TS + Swift) for `invoke` / `subscribe` from the registered command set, replacing the stringly-typed envelope at the call site.
10. **Crisp multi-size Windows `.exe` icon** — the portable `.exe` now embeds the `pwa.json` icon (via `UpdateResource`), but as a single source image the shell downscales; a WIC resize to ship dedicated 16/32/48/256 px slots would sharpen the small sizes.
11. **Built-in live reload on Windows** — the `swift-pwa dev` server is POSIX-only today (macOS / Linux); Windows still needs `--server <url>`.
12. **Homebrew tap** — `brew install tophatch/tap/swift-pwa` as the idiomatic macOS / Linux install + upgrade story. `swift-pwa self-update` already covers the no-brew and Windows cases.

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
