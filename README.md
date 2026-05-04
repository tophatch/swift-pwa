# swift-pwa

A Swift-native, thin-client PWA wrapper around system webviews — Tauri/Wails for the Swift world.

> **Status:** v0.1.0-dev. Window APIs only on macOS 15+, iOS 18+, and Linux (GTK3 + WebKitGTK 4.1). Windows/Android stubs in place; tray, notifications, biometric auth, clipboard land as plugin targets in v0.2+.

## Why

If you write Swift and want to ship a small, single-codebase desktop/mobile app that's mostly a webview wrapping a PWA, your options today are:

- **Electron / Tauri** — fine, but you're not writing Swift.
- **Hand-rolled WKWebView** — locks you to Apple platforms.
- **SwiftUI WebView** — single platform, no JS↔Swift bridge, no bundling story.

`swift-pwa` gives you one Swift package, one JS API (`__SWIFT_PWA__.invoke()`), and one CLI that produces `.app`, `.ipa`, and `.AppImage` from the same source.

## Quickstart

```bash
# Add the package
swift package init --type executable
# In Package.swift, add:
#   .package(url: "https://github.com/<you>/swift-pwa", from: "0.1.0")
# and depend on the "SwiftPWA" product.

swift run swift-pwa init MyApp
cd MyApp
swift run swift-pwa build --target macos
open ./build/MyApp.app
```

## Supported platforms (v0.1)

| Platform | Webview          | Status                |
|---------:|------------------|-----------------------|
| macOS 15 | WKWebView        | First class           |
| iOS 18   | WKWebView        | First class (UIScene) |
| Linux    | WebKitGTK 4.1    | First class (GTK3)    |
| Windows  | WebView2         | Stub (planned v0.2)   |
| Android  | android.webkit   | Stub (planned v0.3)   |

## JS API

```js
// Provided by the bridge runtime, injected at document start.
const ok = await __SWIFT_PWA__.invoke('window.setTitle', { title: 'Hello' });

const unsub = __SWIFT_PWA__.subscribe('window.subscribe', {}, (event) => {
    console.log('window event:', event);
});
// later: unsub();
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

- **`evaluateJavaScript` is fire-and-forget on Linux.** Outbound frames from Swift to JS work because `__deliver` is one-way, but `webView.evaluateJavaScript(_:)` always returns `nil` to Swift on the GTK backend. Apple side is fine. Threading the `GAsyncResult` callback chain back into a Swift continuation is queued.
- **GTK4 / WebKitGTK 6.0 not supported yet.** The C shim assumes the 4.1 ABI (`WebKitJavascriptResult` boxed type on the script-message callback). Adding 6.0 means a sibling shim target with the JSCValue-direct callback.
- **iOS Simulator builds need a runtime install.** `xcodebuild` won't accept iOS Simulator destinations unless the matching iOS platform runtime is installed via *Xcode → Settings → Platforms*. `swift-pwa build --target ios --simulator` works once that's done.
- **Notarization is pass-through, not automated.** `--sign <identity>` invokes `codesign`; users still run `xcrun notarytool submit` manually.
- **Windows / Android bundlers print "not implemented".** Targets are scaffolded but the actual build paths land in v0.2/v0.3.

### Planned

- **v0.2** — Windows (WebView2 + swift-winrt), GTK4/WebKitGTK 6.0, notifications plugin, tray plugin, clipboard plugin.
- **v0.3** — Android (swift-android + JNI), biometric auth plugin, dialog plugin, fs plugin.
- **v0.4+** — Typed JS↔Swift codegen layer, hot reload dev server, notarization automation.

## Platform setup

Per-platform walkthroughs (toolchain, build, codesign, device install, known caveats):

- **macOS** — [docs/macos-setup.md](docs/macos-setup.md): Xcode 26+, `.app` bundling, Developer ID signing, notarization.
- **iOS** — [docs/ios-setup.md](docs/ios-setup.md): Simulator runtime install, `.app` install via `simctl`, device run via Xcode.
- **Linux** — [docs/linux-setup.md](docs/linux-setup.md): Ubuntu 24.04 + Swift 6.0, GTK3 + WebKitGTK 4.1, AppImage builds.

## Contributing

PRs welcome. See [`CHANGELOG.md`](CHANGELOG.md) for what's in flight.

```bash
swift test                                     # unit + WebKit integration on macOS
SWIFT_PWA_LINUX_GUI=1 swift test               # GTK integration tests on Linux
```

## License

Apache-2.0. See [`LICENSE`](LICENSE).
