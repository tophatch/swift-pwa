# swift-pwa

A Swift-native, thin-client PWA wrapper around system webviews — Tauri/Wails for the Swift world.

> **Status:** v0.2 in flight on `main` — clipboard, tray, and notifications plugins shipped on macOS 15+, iOS 18+, Linux (GTK3 + WebKitGTK 4.1, or GTK4 + WebKitGTK 6.0 — selected at build time via `SWIFT_PWA_GTK4=1`), and Windows 11 (Win32 + WebView2, verified on ARM64). Android remains stubbed; biometric auth, dialog, and fs plugins, plus richer Windows toasts via swift-winrt, are queued for v0.3. Last tagged release is v0.1.0.

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

## Supported platforms

| Platform | Webview             | Status                                                               |
|---------:|---------------------|----------------------------------------------------------------------|
| macOS 15 | WKWebView           | First class                                                          |
| iOS 18   | WKWebView           | First class (UIScene)                                                |
| Linux    | WebKitGTK 4.1 / 6.0 | First class (GTK3 default; GTK4 via `SWIFT_PWA_GTK4=1`)              |
| Windows  | WebView2 (Edge)     | First class (Win32 + WebView2; verified on Windows 11 ARM64)         |
| Android  | android.webkit      | Stub (planned v0.3)                                                  |

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

`WindowPlugin` and `ClipboardPlugin` are auto-installed on every backend; `TrayPlugin` is opt-in (creating a tray puts a visible icon up — most apps want to do that conditionally).

- **`WindowPlugin`** — `window.id`, `window.list`, `window.setTitle` / `title`, `window.setSize` / `size`, `window.setPosition` / `position`, `window.focus`, `window.minimize` / `maximize`, `window.setFullscreen` / `isFullscreen`, `window.close`, `window.subscribe`.
- **`ClipboardPlugin`** — `clipboard.readText`, `clipboard.writeText`, `clipboard.clear`. `clear()` wipes the system clipboard on Apple; on X11 / Wayland it only relinquishes local ownership of the selection.
- **`TrayPlugin`** (opt-in) — `tray.setIcon`, `tray.setTooltip`, `tray.setMenu`, `tray.setVisible`, `tray.subscribe`. Add via `ctx.use(TrayPlugin(SystemTray()))`. Full implementation on macOS (`NSStatusItem`) and the GTK3 backend (`libayatana-appindicator3` → StatusNotifierItem over D-Bus, with a fallback to `GtkStatusIcon` on legacy desktops). On iOS and the GTK4 backend `SystemTray()` returns a no-op stub so the same call site works portably — the tray just isn't displayed. `TrayEvent.click` is macOS-only (the SNI spec gives the desktop panel ownership of click semantics on Linux).
- **`NotificationsPlugin`** (opt-in) — `notifications.requestAuthorization`, `notifications.send` (`{title, body?, sound?}` → notification id). Add via `ctx.use(NotificationsPlugin(SystemNotifications()))`. macOS / iOS use `UNUserNotificationCenter` (which requires a bundled, signed app — `swift run` returns "not allowed"); Linux calls `org.freedesktop.Notifications` over D-Bus through GIO, no `libnotify` dep needed.

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

### Known limitations

- **`Window.position()` / `setPosition` are no-ops on the GTK4 backend.** Wayland refuses to give apps their own position, and CSD makes the concept ambiguous; GTK4 dropped the position APIs entirely. `position()` returns `.zero`, `setPosition` silently no-ops, and `.didMove` events are never emitted on GTK4. The GTK3 backend still supports all three.
- **`TrayPlugin` is a no-op on iOS and on the GTK4 backend.** iOS has no system tray. GTK4 removed `GtkStatusIcon`, and the GTK3 path's `libayatana-appindicator3` can't be reused from a GTK4 process (a single process can't link both GTK3 and GTK4); the GTK4-native `libayatana-appindicator-gtk4` isn't yet broadly packaged. On both platforms `SystemTray()` returns a stub that logs a one-shot warning so cross-platform code stays portable.
- **`TrayEvent.click` is macOS-only.** The freedesktop StatusNotifierItem spec gives the desktop panel ownership of click semantics on Linux; apps only see menu activations there.
- **`NotificationsPlugin` requires a bundled, signed `.app` on Apple.** `UNUserNotificationCenter` raises an `NSException` when called from a process without a `CFBundleIdentifier`; the plugin pre-flights and throws a clean `BridgeError` instead of crashing, but actual banners only appear after `swift run swift-pwa build --target macos` (or via Xcode).
- **Notarization is pass-through, not automated.** `--sign <identity>` invokes `codesign`; users still run `xcrun notarytool submit` manually.
- **Windows notifications use the legacy `Shell_NotifyIconW` balloon path.** Banners surface as toasts on Windows 10 / 11, but persistence in Action Center requires a registered AppUserModelID (or a packaged app) — unsigned `swift run` invocations show a transient balloon and nothing in history. Richer toast XML (replace-by-id, action buttons) waits on the swift-winrt dependency planned for v0.3.
- **Android bundler prints "not implemented".** Targets are scaffolded but the actual build path lands in v0.3.

### Planned

- **v0.2** — Windows (Win32 + WebView2) verified on Windows 11 ARM64; clipboard, tray (macOS + GTK3 via libayatana-appindicator3), notifications, the portable `.exe` bundler, and the cross-platform DevTools shortcut (`Cmd+Opt+J` on Apple, `Ctrl+Alt+J` on GTK + Windows) are all in `main`.
- **v0.3** — Android (swift-android + JNI), biometric auth plugin, dialog plugin, fs plugin, GTK4 tray (libayatana-appindicator-gtk4 once it's broadly packaged), Windows toast notifications via swift-winrt + `Windows.UI.Notifications`, MSIX packaging.
- **v0.4+** — Typed JS↔Swift codegen layer, hot reload dev server, notarization automation.

## Platform setup

Per-platform walkthroughs (toolchain, build, codesign, device install, known caveats):

- **macOS** — [docs/macos-setup.md](docs/macos-setup.md): Xcode 26+, `.app` bundling, Developer ID signing, notarization.
- **iOS** — [docs/ios-setup.md](docs/ios-setup.md): Simulator runtime install, `.app` install via `simctl`, device run via Xcode.
- **Linux** — [docs/linux-setup.md](docs/linux-setup.md): Ubuntu 24.04+ + Swift 6.0, GTK3 + WebKitGTK 4.1 by default or GTK4 + WebKitGTK 6.0 via `SWIFT_PWA_GTK4=1`, AppImage builds.
- **Windows** — [docs/windows-setup.md](docs/windows-setup.md): Swift 6 on Windows, Visual Studio Build Tools, the WebView2 SDK / static loader, and the portable `.exe` bundler.

## Contributing

PRs welcome. See [`CHANGELOG.md`](CHANGELOG.md) for what's in flight.

```bash
swift test                                     # unit + WebKit integration on macOS
SWIFT_PWA_LINUX_GUI=1 swift test               # GTK integration tests on Linux
```

## License

Apache-2.0. See [`LICENSE`](LICENSE).
