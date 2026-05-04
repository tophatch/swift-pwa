# swift-pwa

A Swift-native, thin-client PWA wrapper around system webviews — Tauri/Wails for the Swift world.

> **Status:** v0.1.0. Window APIs only on macOS 15+, iOS 18+, and Linux (GTK3 + WebKitGTK 4.1, or GTK4 + WebKitGTK 6.0 — selected at build time via `SWIFT_PWA_GTK4=1`). Windows/Android stubs in place; tray, notifications, biometric auth, clipboard land as plugin targets in v0.2+.

## Why

If you write Swift and want to ship a small, single-codebase desktop/mobile app that's mostly a webview wrapping a PWA, your options today are:

- **Electron / Tauri** — fine, but you're not writing Swift.
- **Hand-rolled WKWebView** — locks you to Apple platforms.
- **SwiftUI WebView** — single platform, no JS↔Swift bridge, no bundling story.

`swift-pwa` gives you one Swift package, one JS API (`__SWIFT_PWA__.invoke()`), and one CLI that produces `.app`, `.ipa`, and `.AppImage` from the same source.

## Quickstart

Scaffold a project from a swift-pwa checkout:

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

## Supported platforms (v0.1)

| Platform | Webview             | Status                                                  |
|---------:|---------------------|---------------------------------------------------------|
| macOS 15 | WKWebView           | First class                                             |
| iOS 18   | WKWebView           | First class (UIScene)                                   |
| Linux    | WebKitGTK 4.1 / 6.0 | First class (GTK3 default; GTK4 via `SWIFT_PWA_GTK4=1`) |
| Windows  | WebView2            | Stub (planned v0.2)                                     |
| Android  | android.webkit      | Stub (planned v0.3)                                     |

## JS API

```js
// Provided by the bridge runtime, injected at document start.
const ok = await __SWIFT_PWA__.invoke('window.setTitle', { title: 'Hello' });

const unsub = __SWIFT_PWA__.subscribe('window.subscribe', {}, (event) => {
    console.log('window event:', event);
});
// later: unsub();

// Built-in clipboard plugin (auto-installed on every backend).
await __SWIFT_PWA__.invoke('clipboard.writeText', { text: 'copied!' });
const { text } = await __SWIFT_PWA__.invoke('clipboard.readText');
```

### Built-in plugins

Both ship enabled out of the box; no `ctx.use(...)` needed.

- **`WindowPlugin`** — `window.id`, `window.list`, `window.setTitle` / `title`, `window.setSize` / `size`, `window.setPosition` / `position`, `window.focus`, `window.minimize` / `maximize`, `window.setFullscreen` / `isFullscreen`, `window.close`, `window.subscribe`.
- **`ClipboardPlugin`** — `clipboard.readText`, `clipboard.writeText`, `clipboard.clear`. `clear()` wipes the system clipboard on Apple; on X11 / Wayland it only relinquishes local ownership of the selection.

## Swift API

```swift
import SwiftPWA

@main
struct HelloApp {
    static func main() async throws {
        let runtime = try SwiftPWA.runtime()
        try runtime.run { ctx in
            // Register a custom command
            await ctx.registry.register("ping") { (_: EmptyArgs, _) in
                "pong"
            }

            _ = try ctx.createWindow(.init(
                title: "Hello",
                size: .init(width: 1024, height: 768),
                content: .bundled(Bundle.main.bundleURL.appendingPathComponent("web/index.html"))
            ))
        }
    }
}
```

## Bundling

```bash
swift run swift-pwa build --target macos                 # → MyApp.app
swift run swift-pwa build --target macos --sign "Developer ID Application: Acme"
swift run swift-pwa build --target ios --simulator       # → unsigned .app for sim
swift run swift-pwa build --target linux                 # → MyApp-x86_64.AppImage
```

The `pwa.json` manifest in your project root is the source of truth — `Info.plist`, `.desktop`, and icon assets are all generated from it.

## Comparison

|                  | swift-pwa | Tauri    | Wails    | Electron |
|------------------|-----------|----------|----------|----------|
| Host language    | Swift     | Rust     | Go       | Node.js  |
| Webview          | System    | System   | System   | Bundled  |
| Bundle size      | ~5-15 MB  | ~5-15 MB | ~5-15 MB | ~80+ MB  |
| iOS              | Yes       | No       | No       | No       |

## Roadmap

### Known limitations in v0.1

- **`Window.position()` / `setPosition` are no-ops on the GTK4 backend.** Wayland refuses to give apps their own position, and CSD makes the concept ambiguous; GTK4 dropped the position APIs entirely. `position()` returns `.zero`, `setPosition` silently no-ops, and `.didMove` events are never emitted on GTK4. The GTK3 backend still supports all three.
- **Notarization is pass-through, not automated.** `--sign <identity>` invokes `codesign`; users still run `xcrun notarytool submit` manually.
- **Windows / Android bundlers print "not implemented".** Targets are scaffolded but the actual build paths land in v0.2/v0.3.

### Planned

- **v0.2** — Windows (WebView2 + swift-winrt), notifications plugin, tray plugin, clipboard plugin.
- **v0.3** — Android (swift-android + JNI), biometric auth plugin, dialog plugin, fs plugin.
- **v0.4+** — Typed JS↔Swift codegen layer, hot reload dev server, notarization automation.

## Platform setup

Per-platform walkthroughs (toolchain, build, codesign, device install, known caveats):

- **macOS** — [docs/macos-setup.md](docs/macos-setup.md): Xcode 26+, `.app` bundling, Developer ID signing, notarization.
- **iOS** — [docs/ios-setup.md](docs/ios-setup.md): Simulator runtime install, `.app` install via `simctl`, device run via Xcode.
- **Linux** — [docs/linux-setup.md](docs/linux-setup.md): Ubuntu 24.04+ + Swift 6.0, GTK3 + WebKitGTK 4.1 by default or GTK4 + WebKitGTK 6.0 via `SWIFT_PWA_GTK4=1`, AppImage builds.

## Contributing

PRs welcome. See [`CHANGELOG.md`](CHANGELOG.md) for what's in flight.

```bash
swift test                                     # unit + WebKit integration on macOS
SWIFT_PWA_LINUX_GUI=1 swift test               # GTK integration tests on Linux
```

## License

Apache-2.0. See [`LICENSE`](LICENSE).
