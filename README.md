# swift-pwa

A Swift-native, thin-client PWA wrapper around system webviews — Tauri/Wails for the Swift world.

> **Status:** [`v0.3.0`](https://github.com/tophatch/swift-pwa/releases/tag/v0.3.0) is the current release. Windows WinRT toasts, Per-Monitor V2 DPI, MSIX packaging, the opt-in WebView2 Evergreen Bootstrapper, a Windows binary in the release matrix, and the cross-platform auto-updater (Apple backend) all land in v0.3 — verified end-to-end on Windows 11 amd64 and ARM64 plus macOS 15. macOS 15+, iOS 18+, Linux (GTK3 + WebKitGTK 4.1, or GTK4 + WebKitGTK 6.0 via `SWIFT_PWA_GTK4=1`), and Windows 11 (Win32 + WebView2) are first-class. Built-in plugins: window, clipboard, tray, notifications, updater. `Cmd+Opt+J` / `Ctrl+Alt+J` opens DevTools on every backend. Android, biometric auth / dialog / fs plugins, the Linux AppImage + Windows updater backends, and the `swift-pwa updater` CLI subcommands are queued for v0.4.

## Why

If you write Swift, today's options for shipping a thin-client app are uncomfortable:

- **Electron** ships an 80 MB Chromium with every download, in JavaScript. Desktop only.
- **Tauri** is small, fast, and reaches mobile — but you're writing Rust.
- **Wails** is small and fast in Go — but desktop only.
- **Hand-rolled WKWebView** locks you to Apple, and you're rebuilding the JS↔Swift bridge, the bundler, and the multi-window plumbing yourself.
- **SwiftUI WebView** is single-platform and ships no bridge or bundling story.

`swift-pwa` is the option for Swift shops: one Swift package, one JS API (`__SWIFT_PWA__.invoke()`), one CLI. The same source produces `.app`, `.ipa`, `.AppImage`, portable Windows `.exe`, and MSIX, with Android queued for v0.4.

|                  | **swift-pwa**  | Tauri    | Wails    | Electron |
|------------------|----------------|----------|----------|----------|
| Host language    | Swift          | Rust     | Go       | Node.js  |
| Webview          | System         | System   | System   | Bundled  |
| Bundle size      | ~5-15 MB       | ~5-15 MB | ~5-15 MB | ~80+ MB  |
| macOS            | Yes            | Yes      | Yes      | Yes      |
| Linux            | Yes            | Yes      | Yes      | Yes      |
| Windows          | Yes            | Yes      | Yes      | Yes      |
| iOS              | Yes            | Yes      | No       | No       |
| Android          | Planned (v0.4) | Yes      | No       | No       |

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

Or build the CLI from source (works on every platform, including Windows):

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

| Platform | Webview             | Status                                                                                       |
|---------:|---------------------|----------------------------------------------------------------------------------------------|
| macOS 15 | WKWebView           | First class                                                                                  |
| iOS 18   | WKWebView           | First class (UIScene)                                                                        |
| Linux    | WebKitGTK 4.1 / 6.0 | First class (GTK3 default; GTK4 via `SWIFT_PWA_GTK4=1`)                                      |
| Windows  | WebView2 (Edge)     | First class (Win32 + WebView2; Per-Monitor V2 DPI; WinRT toasts; portable `.exe` and MSIX)   |
| Android  | android.webkit      | Stub (planned v0.4)                                                                          |

## Features

A capability index. Anything with a dedicated doc links out; anything without is documented inline below or in the platform setup docs.

### Bridge & runtime

- **Tauri-style JS↔Swift bridge** — `__SWIFT_PWA__.invoke(cmd, args)` for unary, `__SWIFT_PWA__.subscribe(cmd, args, onChunk)` for streaming. Wire envelope is one frame format across WKWebView, WebKitGTK, and WebView2. See [JS API](#js-api) and [Swift API](#swift-api) below.
- **`bridge.js` injected at document start** — calls work before user JS loads. Three native message channels picked automatically (WKWebView `messageHandlers`, WebKitGTK `script_message_handler`, WebView2 `chrome.webview`).
- **Bundled-asset scheme handler** — `pwa://localhost/...` on Apple / Linux, `https://swift-pwa.local/...` on Windows (WebView2's `SetVirtualHostNameToFolderMapping`). Relative URLs / `fetch` / ESM all work without a local dev server.
- **Custom commands** — `ctx.registry.register("ping") { (_: Args, _) in result }`. Plugins are just bundles of commands sharing a name; see `Plugin.swift`.

### Built-in plugins

Auto-installed on every backend:

- **`WindowPlugin`** — `window.id` / `list`, `setTitle` / `title`, `setSize` / `size`, `setPosition` / `position`, `focus`, `minimize` / `maximize`, `setFullscreen` / `isFullscreen`, `close`, `subscribe` (streaming events). Multi-window on macOS / Linux / Windows; UIScene-aware on iOS (single scene polished, multi-scene scaffolded).
- **`ClipboardPlugin`** — `clipboard.readText`, `writeText`, `clear`. (`clear` wipes on Apple; on X11 / Wayland it only relinquishes local ownership of the selection.)

Opt-in (add via `ctx.use(...)`):

- **`TrayPlugin`** — `tray.setIcon` / `setTooltip` / `setMenu` / `setVisible` / `subscribe`. Full impl on macOS (`NSStatusItem`) and GTK3 (`libayatana-appindicator3` → StatusNotifierItem over D-Bus); no-op stub on iOS and GTK4 (no available system tray). `TrayEvent.click` is macOS-only (SNI gives the desktop panel click semantics on Linux).
- **`NotificationsPlugin`** — `notifications.requestAuthorization`, `send`. macOS / iOS use `UNUserNotificationCenter` (requires a bundled, signed app — see [docs/macos-setup.md](docs/macos-setup.md#known-limitations-on-macos)); Linux uses GIO D-Bus to `org.freedesktop.Notifications` (no `libnotify` dep); Windows uses `Windows.UI.Notifications.ToastNotificationManager` via a C++/WinRT shim with `Shell_NotifyIconW` balloon fallback (see [docs/windows-setup.md](docs/windows-setup.md)).
- **`UpdaterPlugin`** — `updater.check`, `updater.run` (streaming), `updater.installAndRelaunch`. macOS bundle swap and iOS enterprise / ad-hoc ship in v0.3; Linux AppImage and Windows MSIX / portable queued for v0.4. See [docs/auto-updates.md](docs/auto-updates.md).

### Bundling & distribution

`swift-pwa build --target <platform>` produces a native artifact from one source tree. `pwa.json` is the source of truth — `Info.plist`, `.desktop`, `AppxManifest.xml`, and icon assets are all generated from it.

| Platform | Artifact                                                 | Setup                                          |
|----------|----------------------------------------------------------|------------------------------------------------|
| macOS    | `.app` (+ Developer ID `--sign` pass-through)            | [docs/macos-setup.md](docs/macos-setup.md)     |
| iOS      | `.app` (Simulator) / `.ipa` (device, partial)            | [docs/ios-setup.md](docs/ios-setup.md)         |
| Linux    | `.AppImage` (via `linuxdeploy`)                          | [docs/linux-setup.md](docs/linux-setup.md)     |
| Windows  | Portable folder bundle or MSIX (`--package-format msix`) | [docs/windows-setup.md](docs/windows-setup.md) |

See [Bundling](#bundling) below for the command reference.

### Platform polish

- **Per-Monitor V2 DPI on Windows.** `setSize` / `position` convert at API boundaries; `WM_DPICHANGED` accepts the OS-suggested rect verbatim. Non-client (titlebar, scrollbars) scales correctly. Details in [docs/windows-setup.md](docs/windows-setup.md).
- **Cross-platform DevTools shortcut.** `Cmd+Opt+J` on macOS (WKWebView's `_showInspector:` SPI), `Ctrl+Alt+J` on GTK3/4 (`webkit_web_inspector_show`), `Ctrl+Alt+J` on Windows (WebView2's `OpenDevToolsWindow`).
- **Opt-in WebView2 Evergreen Bootstrapper** (`--bootstrap-webview2`) — bundle a ~1.7 MB Microsoft installer next to your EXE for fresh boxes without the WebView2 Runtime. See [docs/windows-setup.md](docs/windows-setup.md).
- **Two parallel Linux backends** — GTK3 + WebKitGTK 4.1 by default for Ubuntu 22.04+ / Fedora 36+; GTK4 + WebKitGTK 6.0 via `SWIFT_PWA_GTK4=1` for newer distros. Same Swift module name (`SwiftPWAGTK`) so the umbrella doesn't change. See [docs/linux-setup.md](docs/linux-setup.md).

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
swift run swift-pwa build --target windows               # → build\MyApp\MyApp.exe (+ web/, pwa.json)
swift run swift-pwa build --target windows --package-format msix --sign <thumbprint>
swift run swift-pwa build --target windows --bootstrap-webview2  # bundle the WebView2 Evergreen Bootstrapper
```

The `pwa.json` manifest in your project root is the source of truth — `Info.plist`, `.desktop`, and icon assets are all generated from it.

## Roadmap

### Known limitations

- **`Window.position()` / `setPosition` are no-ops on the GTK4 backend.** Wayland refuses to give apps their own position, and CSD makes the concept ambiguous; GTK4 dropped the position APIs entirely. `position()` returns `.zero`, `setPosition` silently no-ops, and `.didMove` events are never emitted on GTK4. The GTK3 backend still supports all three.
- **`TrayPlugin` is a no-op on iOS and on the GTK4 backend.** iOS has no system tray. GTK4 removed `GtkStatusIcon`, and the GTK3 path's `libayatana-appindicator3` can't be reused from a GTK4 process (a single process can't link both GTK3 and GTK4); the GTK4-native `libayatana-appindicator-gtk4` isn't yet broadly packaged. On both platforms `SystemTray()` returns a stub that logs a one-shot warning so cross-platform code stays portable.
- **`TrayEvent.click` is macOS-only.** The freedesktop StatusNotifierItem spec gives the desktop panel ownership of click semantics on Linux; apps only see menu activations there.
- **`NotificationsPlugin` requires a bundled, signed `.app` on Apple.** `UNUserNotificationCenter` raises an `NSException` when called from a process without a `CFBundleIdentifier`; the plugin pre-flights and throws a clean `BridgeError` instead of crashing, but actual banners only appear after `swift run swift-pwa build --target macos` (or via Xcode).
- **Notarization is pass-through, not automated.** `--sign <identity>` invokes `codesign`; users still run `xcrun notarytool submit` manually.
- **Windows toast persistence in Action Center requires a Start-menu shortcut.** The runtime sets a stable AppUserModelID (`SwiftPWA.<exe-stem>`) at process start which is enough for toasts to show, but Windows only keeps them in Action Center across reboots when the AUMID also matches a registered Start-menu `.lnk`. The MSIX bundler path takes care of this; portable bundles shipped outside an installer don't get persistence.
- **Android bundler prints "not implemented".** Targets are scaffolded but the actual build path lands in v0.3.
- **Auto-updates ship Apple-only in v0.3.** `AppleUpdater` covers macOS bundle swap and iOS enterprise / ad-hoc via `itms-services://`. Linux AppImage (atomic-rename onto the running mmap) and Windows MSIX / portable updaters are queued for v0.4, along with the `swift-pwa updater keygen / sign / manifest` CLI subcommands. macOS install fires no UI before the swap — apps that want a "Restart now / later" prompt should gate `updater.installAndRelaunch` behind their own dialog.

### Planned

- **v0.4** — Android (swift-android + JNI), biometric auth plugin, dialog plugin, fs plugin, GTK4 tray (libayatana-appindicator-gtk4 once it's broadly packaged), auto-updater on Linux AppImage + Windows MSIX/portable, `swift-pwa updater` CLI (keygen / sign / manifest), minisign-format key + signature parsing, MSIX `--arch arm64` for cross-arch packages, streaming `URLSessionDownloadDelegate`-driven progress for the macOS updater.
- **v0.5+** — Typed JS↔Swift codegen layer, hot reload dev server, notarization automation, delta updates, mandatory-update kill-switch (`min_supported_version`).

See [`CHANGELOG.md`](CHANGELOG.md) for the per-release breakdown of what's already shipped.

## Platform setup

Per-platform walkthroughs (toolchain, build, codesign, device install, known caveats):

- **macOS** — [docs/macos-setup.md](docs/macos-setup.md): Xcode 26+, `.app` bundling, Developer ID signing, notarization.
- **iOS** — [docs/ios-setup.md](docs/ios-setup.md): Simulator runtime install, `.app` install via `simctl`, device run via Xcode.
- **Linux** — [docs/linux-setup.md](docs/linux-setup.md): Ubuntu 24.04+ + Swift 6.0, GTK3 + WebKitGTK 4.1 by default or GTK4 + WebKitGTK 6.0 via `SWIFT_PWA_GTK4=1`, AppImage builds.
- **Windows** — [docs/windows-setup.md](docs/windows-setup.md): Swift 6 on Windows, Visual Studio Build Tools, the WebView2 SDK / static loader, and the portable `.exe` bundler.

## Contributing

PRs welcome. See [`CHANGELOG.md`](CHANGELOG.md) for what shipped, what's in `Unreleased`, and the running list of release notes.

```bash
swift test                                     # unit + WebKit integration on macOS
SWIFT_PWA_LINUX_GUI=1 swift test               # GTK integration tests on Linux
```

## License

Apache-2.0. See [`LICENSE`](LICENSE).
