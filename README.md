# swift-pwa

A Swift-native, thin-client PWA wrapper around system webviews — Tauri/Wails for the Swift world.

> **Status:** [`v0.4.0`](https://github.com/tophatch/swift-pwa/releases/tag/v0.4.0) is the current release; macOS 15+, iOS 18+, Linux (GTK3 / GTK4), and Windows 11 (WebView2) are all first-class. **v0.5 is in flight on `main` and starts with Android** (Swift backend, JNI shim, Kotlin / Gradle scaffold, vendored Gradle 8.10.2 wrapper, `swift-pwa build --target android` → `./gradlew assembleDebug` → `adb install`, verified end-to-end on a Samsung Galaxy Tab S10+ — `Examples/HelloPWA` loads, the JS↔Swift bridge round-trips, and the Window / Bridge / Filesystem / Updater plugins all work; Clipboard / Tray / Dialog / Notifications / Biometrics System*-backends are queued for v0.5.x). See the [feature matrix](#feature-matrix) for what works where, [docs/android-setup.md](docs/android-setup.md) for the Android wiring, and [`CHANGELOG.md`](CHANGELOG.md) for the per-release breakdown.

## Why

If you write Swift, today's options for shipping a thin-client app are uncomfortable:

- **Electron** ships an 80 MB Chromium with every download, in JavaScript. Desktop only.
- **Tauri** is small, fast, and reaches mobile — but you're writing Rust.
- **Wails** is small and fast in Go — but desktop only.
- **Hand-rolled WKWebView** locks you to Apple, and you're rebuilding the JS↔Swift bridge, the bundler, and the multi-window plumbing yourself.
- **SwiftUI WebView** is single-platform and ships no bridge or bundling story.

`swift-pwa` is the option for Swift shops: one Swift package, one JS API (`__SWIFT_PWA__.invoke()`), one CLI. The same source produces `.app`, `.ipa`, `.AppImage`, portable Windows `.exe`, MSIX, and (preview, v0.5) an Android Gradle project that builds to APK / AAB.

|                  | **swift-pwa**  | Tauri    | Wails    | Electron |
|------------------|----------------|----------|----------|----------|
| Host language    | Swift          | Rust     | Go       | Node.js  |
| Webview          | System         | System   | System   | Bundled  |
| Bundle size      | ~5-15 MB       | ~5-15 MB | ~5-15 MB | ~80+ MB  |
| macOS            | Yes            | Yes      | Yes      | Yes      |
| Linux            | Yes            | Yes      | Yes      | Yes      |
| Windows          | Yes            | Yes      | Yes      | Yes      |
| iOS              | Yes            | Yes      | No       | No       |
| Android          | Preview (v0.5) | Yes      | No       | No       |

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

Or build the CLI from source (works on every platform, including Windows on ARM64):

```bash
git clone https://github.com/tophatch/swift-pwa
swift run --package-path swift-pwa swift-pwa init MyApp
cd MyApp
```

You get a self-contained SwiftPM project:

```text
MyApp/
├── Package.swift              # depends on SwiftPWA
├── pwa.json                   # source of truth — generates Info.plist / .desktop / bundle metadata
├── Sources/MyApp/App.swift    # @main entry point; creates a window pointing at web/
└── web/
    └── index.html             # your frontend's entry point
```

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
    "name": "MyApp",
    "version": "0.1.0",
    "description": "An optional one-liner.",
    "icon": "icon.png",
    "web": { "directory": "web", "entry": "index.html" },
    "window": {
        "title": "MyApp",
        "width": 1024,
        "height": 768,
        "resizable": true,
        "fullscreen": false
    },
    "macos": {
        "bundle_identifier": "com.example.myapp",
        "category": "public.app-category.productivity",
        "minimum_system_version": "15.0",
        "copyright": "© 2026 Acme Corp."
    },
    "ios": {
        "bundle_identifier": "com.example.myapp",
        "minimum_system_version": "18.0"
    },
    "linux": {
        "desktop_categories": ["Utility"]
    }
}
```

Required keys: `id`, `name`, `version`, `web`, `window`. The `macos` / `ios` / `linux` sections are optional — omit any platform you don't ship to. `icon` should be a 1024×1024 PNG; on macOS it's converted to `.icns`, on Linux it's embedded in the AppImage. `category` on macOS is the `LSApplicationCategoryType` UTI shown in the App Store / Finder. `description` and `macos.copyright` populate the **About** panel (the description becomes the body text, the copyright shows under the version).

### Build and run

```bash
swift run swift-pwa build --target macos
open ./build/MyApp.app
```

For codesigning, device deployment, and Linux GTK setup, see [Platform setup](#platform-setup).

## Feature matrix

`Yes` = first-class. `Partial` = works with documented caveats (footnoted; per-platform detail in the matching [docs/&lt;platform&gt;-setup.md](docs/)). `Preview` = code-complete and host-buildable, not yet verified end-to-end on the platform. `—` = not applicable. `v0.5.x` = on the roadmap inside the active cycle.

| Capability                    | macOS                   | iOS                          | Linux GTK3                 | Linux GTK4              | Windows                  | Android                  |
| ----------------------------- | :---------------------: | :--------------------------: | :------------------------: | :---------------------: | :----------------------: | :----------------------: |
| Webview                       | WKWebView               | WKWebView                    | WebKitGTK 4.1              | WebKitGTK 6.0           | WebView2 (Edge)          | android.webkit.WebView   |
| Min OS / runtime              | macOS 15                | iOS 18                       | Ubuntu 22.04+ / Fedora 36+ | GTK 4.10+               | Win10 21H2+ + WebView2   | API 26 (Android 8.0)     |
| JS↔Swift bridge               | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Preview⁷                 |
| Multi-window                  | Yes                     | Partial¹                     | Yes                        | Yes                     | Yes                      | —⁸                       |
| DevTools (`Cmd/Ctrl+Alt+J`)   | Yes                     | —                            | Yes                        | Yes                     | Yes                      | Remote⁹                  |
| Per-Monitor V2 DPI            | —                       | —                            | —                          | —                       | Yes                      | —                        |
| `WindowPlugin`                | Yes                     | Yes                          | Yes                        | Partial²                | Yes                      | Partial⁸                 |
| `ClipboardPlugin`             | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | v0.5.x                   |
| `DialogPlugin`                | Yes                     | Partial³                     | Yes                        | Yes⁴                    | Yes                      | v0.5.x                   |
| `FsPlugin`                    | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Preview⁷                 |
| `TrayPlugin`                  | Yes                     | —                            | Yes                        | —                       | Yes                      | —                        |
| `NotificationsPlugin`         | Yes⁵                    | Yes⁵                         | Yes                        | Yes                     | Yes                      | v0.5.x                   |
| `BiometricAuthPlugin`         | Touch / Face ID         | Touch / Face / Optic ID      | —                          | —                       | Windows Hello            | v0.5.x                   |
| `UpdaterPlugin` (runtime)     | Untested⁶               | Untested⁶                    | Untested⁶                  | Untested⁶               | Untested⁶                | v0.5.x                   |
| `swift-pwa updater` CLI       | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | v0.5.x                   |
| Bundler artifact              | `.app`                  | `.app` / `.ipa`              | `.AppImage`                | `.AppImage`             | Portable / MSIX          | Gradle project → APK/AAB |
| Code-signing pass-through     | `codesign`              | `codesign`                   | —                          | —                       | `signtool`               | v0.5.x¹⁰                 |

1. iOS UIScene single scene polished, multi-scene scaffolded.
2. `Window.position()` / `setPosition` / `.didMove` are no-ops on GTK4 (Wayland refuses to give apps their own position).
3. `dialog.saveFile` is a stub — iOS has no system save panel.
4. GTK4 dialogs require GTK 4.10+ (`GtkAlertDialog` / `GtkFileDialog`).
5. Apple notifications require a bundled, signed `.app` (`UNUserNotificationCenter` rejects unsigned processes).
6. Runtime updater backends are implemented and unit-tested (134 tests pass) but **the OS-level install paths haven't been walked end-to-end against real bundled artifacts in this release** — `ditto` swap on macOS, atomic `rename(2)` on Linux, `Move-Item` / `Add-AppxPackage` on Windows, `itms-services://` on iOS. Treat as preview until the [docs/manual-test-cases.md](docs/manual-test-cases.md) checklist is walked. The publishing CLI (`swift-pwa updater keygen / sign / manifest`) is in tested status — the surface that's flagged is only the runtime backends that hand off to the OS.
7. Android backend (Swift target, JNI shim, Kotlin scaffold, `swift-pwa build --target android` bundler) lands in v0.5.0; **end-to-end verification on a real device or emulator is queued for v0.5.1** once swift-android-sdk distribution shape stabilizes. Treat as preview. See [docs/android-setup.md](docs/android-setup.md) for the wiring + boilerplate.
8. Multi-window on Android maps to Activity-per-window, which doesn't fit the desktop multi-window UX cleanly; queued for v0.5.x. Most `Window` APIs (`setSize`, `setPosition`, `minimize`, `maximize`, `focus`) are no-ops on Android because the platform owns those decisions; documented in [docs/android-setup.md](docs/android-setup.md).
9. Android `WebView` exposes no programmatic DevTools window; remote debugging via `chrome://inspect` on a connected host is the only path. `webView.openDevTools()` logs an `adb`-friendly hint to make the call visibly effective.
10. Android signing goes through Gradle's `signingConfigs`. The bundler doesn't emit one in v0.5.0; until it does, `assembleRelease` requires the user to edit `app/build.gradle.kts` and add their keystore manually.

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
        content: .bundled(Bundle.main.bundleURL.appendingPathComponent("web/index.html"))
    ))
}
```

## Bundling

```bash
swift run swift-pwa build --target macos                              # → MyApp.app
swift run swift-pwa build --target macos --sign "Developer ID Application: Acme"
swift run swift-pwa build --target ios --simulator                    # unsigned .app for sim
swift run swift-pwa build --target linux                              # → MyApp-x86_64.AppImage
swift run swift-pwa build --target windows                            # → portable folder bundle
swift run swift-pwa build --target windows --package-format msix --arch arm64 --sign <thumbprint>
swift run swift-pwa build --target windows --bootstrap-webview2       # bundle the Evergreen Bootstrapper
swift run swift-pwa build --target android                            # → MyApp-android/ Gradle project (preview)
swift run swift-pwa build --target android --cross-compile-android --android-abis arm64-v8a,x86_64
```

`pwa.json` is the source of truth — `Info.plist`, `.desktop`, `AppxManifest.xml`, and icon assets all generate from it. Per-target setup (toolchain, codesign, device install) lives under [Platform setup](#platform-setup).

The `swift-pwa updater` subcommand publishes auto-update manifests (`keygen`, `sign`, `manifest`) — see [docs/auto-updates.md](docs/auto-updates.md).

## Roadmap

- **v0.5** (in flight on `main`) — **Android backend kickoff:** `SwiftPWAAndroid` Swift target, JNI shim, Kotlin / Gradle scaffold, `swift-pwa build --target android`. Preview status until end-to-end device verification lands in v0.5.1 — see [docs/android-setup.md](docs/android-setup.md). Also queued: GTK4 tray (retire `libayatana-appindicator` for `libayatana-appindicator-glib` so the same shim works on both backends), Android `Updater` + dialog / clipboard / notifications / biometric backends.
- **v0.5+** — Typed JS↔Swift codegen layer, hot-reload dev server, notarization automation, delta updates, mandatory-update kill-switch (`min_supported_version`).

Per-platform "Known limitations" sections in each [docs/&lt;platform&gt;-setup.md](docs/) cover the long tail. [`CHANGELOG.md`](CHANGELOG.md) has the per-release breakdown.

## Platform setup

Per-platform walkthroughs (toolchain, build, codesign, device install, known caveats):

- **macOS** — [docs/macos-setup.md](docs/macos-setup.md): Xcode 26+, `.app` bundling, Developer ID signing, notarization.
- **iOS** — [docs/ios-setup.md](docs/ios-setup.md): Simulator runtime install, `.app` install via `simctl`, device run via Xcode.
- **Linux** — [docs/linux-setup.md](docs/linux-setup.md): Ubuntu 24.04+ + Swift 6.0, GTK3 + WebKitGTK 4.1 by default or GTK4 + WebKitGTK 6.0 via `SWIFT_PWA_GTK4=1`, AppImage builds.
- **Windows** — [docs/windows-setup.md](docs/windows-setup.md): Swift 6 on Windows, Visual Studio Build Tools, the WebView2 SDK / static loader, and the portable `.exe` bundler.
- **Android** *(preview)* — [docs/android-setup.md](docs/android-setup.md): Swift 6.1+ Android target via swift-android-sdk, NDK r26+, JDK 17 + AGP 8.5, the `@_cdecl` entry-point boilerplate, and the Gradle scaffold the `swift-pwa build --target android` bundler emits.

## Contributing

PRs welcome. See [`CHANGELOG.md`](CHANGELOG.md) for what shipped, what's in `Unreleased`, and the running list of release notes.

```bash
swift test                                     # unit + WebKit integration on macOS
SWIFT_PWA_LINUX_GUI=1 swift test               # GTK integration tests on Linux
```

Before tagging a release, walk the manual cases in [docs/manual-test-cases.md](docs/manual-test-cases.md) — they cover the OS-level install machinery, on-device installer flows, and visual smoothness checks that the unit suite can't reach.

## License

Apache-2.0. See [`LICENSE`](LICENSE).
