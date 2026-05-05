# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`swift-pwa` is a Swift-native thin-client PWA wrapper around system webviews — a Tauri/Wails analogue for the Swift world. One Swift package, one JS API (`__SWIFT_PWA__.invoke()` / `subscribe()`), one CLI (`swift-pwa`) that produces `.app`, `.ipa`, `.AppImage`, and Windows portable / MSIX from the same source. Status: v0.3 in flight on `main` (Windows WinRT toasts, Per-Monitor V2 DPI, MSIX packaging, opt-in WebView2 Evergreen Bootstrapper, Windows release-matrix binary); last tagged release is v0.2.0.

## Common commands

```bash
swift build                                    # build everything (Apple)
swift test                                     # unit + WKWebView integration on macOS
swift test --filter SwiftPWACoreTests          # run a single test target
swift test --filter BridgeRuntimeTests         # filter by suite name
SWIFT_PWA_LINUX_GUI=1 swift test               # opt-in GTK integration on Linux
swiftformat --lint .                           # CI's lint check
swiftformat .                                  # apply formatting
swift run swift-pwa init MyApp                 # scaffold a new app
swift run swift-pwa build --target macos       # bundle .app
swift run swift-pwa build --target ios --simulator
swift run swift-pwa build --target linux       # AppImage (needs linuxdeploy)
```

On Linux, only `SwiftPWACore` + `swift-pwa-cli` are gated by CI; full `SwiftPWAGTK` builds need `libgtk-3-dev` + `libwebkit2gtk-4.1-dev` (see [docs/linux-setup.md](docs/linux-setup.md)). iOS Simulator builds go through `xcodebuild` against the `SwiftPWA` scheme — Apple does not ship a Swift SDK that `swift build --triple` can target for iOS.

## Architecture

The package is layered as **core → backend → umbrella**:

- **`SwiftPWACore`** (platform-agnostic) — defines `AppRuntime`, `AppContext`, `Window`, `PWAWebView` protocols; the `BridgeRuntime`, `CommandRegistry`, `Invocation` envelope, `Plugin` model, and the built-in `WindowPlugin` exposing `window.*` JS commands. Also ships `Resources/bridge.js`, the JS-side runtime injected at document-start.
- **`SwiftPWAWebKit`** ([Sources/SwiftPWAWebKit/](Sources/SwiftPWAWebKit/)) — Apple backend (macOS 15+, iOS 18+) wrapping `WKWebView` with a `pwa://` scheme handler and UIScene multi-window scaffolding. Conditionally compiled `.when(platforms: [.macOS, .iOS])`.
- **`SwiftPWAGTK`** — Linux backend, hand-rolled C shims. Two parallel implementations selected at build time via the `SWIFT_PWA_GTK4` environment variable read in [Package.swift](Package.swift):
  - **Default** (GTK3 + WebKitGTK 4.1): sources in [Sources/SwiftPWAGTK/](Sources/SwiftPWAGTK/) + [Sources/CGtk3Shim/](Sources/CGtk3Shim/) + [Sources/CWebKitGTK4Shim/](Sources/CWebKitGTK4Shim/).
  - **`SWIFT_PWA_GTK4=1`** (GTK4 + WebKitGTK 6.0): sources in [Sources/SwiftPWAGTK4/](Sources/SwiftPWAGTK4/) + [Sources/CGtk4Shim/](Sources/CGtk4Shim/) + [Sources/CWebKitGTK6Shim/](Sources/CWebKitGTK6Shim/).
  - Both export the same `SwiftPWAGTK` Swift module name (Package.swift swaps `path`), so the umbrella and downstream code don't change. Conditionally compiled `.when(platforms: [.linux])`.
- **`SwiftPWA`** (umbrella) — the only module users import. `@_exported`s core + the platform backend, exposes `SwiftPWA.runtime()` which returns the platform-appropriate `AppRuntime`.
- **`swift-pwa-cli`** — `init`, `dev`, `build` subcommands; bundlers for `.app` (Mac), `.ipa` (iOS via `xcodebuild`), `.AppImage` (Linux via `linuxdeploy`); `pwa.json` is the source of truth for `Info.plist`/`.desktop`/icon generation.
- **`_SwiftPWATestSupport`** — reusable `MockWindow` / `MockWebView` / `MockAppContext` consumed by all test targets.

### The bridge

JS↔Swift uses a Tauri-style envelope `{v, kind, id, cmd, payload}`. Every backend webview adapter funnels inbound `invoke` / `subscribe` / `unsubscribe` frames through `BridgeRuntime.handle`, which dispatches into a single `CommandRegistry`. Outbound frames go through `webView.deliver(...)` (`reply` / `replyError` / `event` / `end`). `invoke` is unary; `subscribe` is streaming (each yield from a typed handler becomes an `event` frame, completion becomes `end`).

### Concurrency model — important

This is the trickiest part of the codebase and the source of past bugs:

- **`CommandRegistry` is a class, not an actor.** It uses `NSLock` and `@unchecked Sendable`. Registration is *synchronous* on purpose so user `configure` closures can run on a thread that isn't pumping Swift's MainActor executor (e.g. before `gtk_main()` enters its loop on Linux).
- **`BridgeRuntime` is *not* `@MainActor`.** Its pump task runs on the cooperative pool. Backend `PWAWebView.deliver` implementations are responsible for hopping to the platform UI thread internally. The previous `@MainActor`-ised design hung on Linux because `gtk_main()` doesn't drain libdispatch's main queue, which is what Swift's MainActor is backed by.
- **`MainThread.run` ([Sources/SwiftPWACore/MainThread.swift](Sources/SwiftPWACore/MainThread.swift)) is the canonical "run this on the UI thread" abstraction.** It routes through a per-backend dispatch hook installed at startup: Apple registers a `DispatchQueue.main`-based hook, GTK registers one that schedules via `g_idle_add`. The closure stays `@MainActor`-annotated; `MainActor.assumeIsolated` satisfies the runtime check once execution lands on the UI thread. Use this rather than `await MainActor.run` in any code path that may execute under `gtk_main`.

### Linux backend caveats

- **Two parallel backends, picked at build time.** `SWIFT_PWA_GTK4=1` swaps which directory contributes the Swift sources for the `SwiftPWAGTK` target and which C shims it depends on. Both expose the same Swift class names (`GTKWindow`, `GTKAppContext`, `GTKAppRuntime`, `WebKitGTKAdapter`) so the umbrella and tests don't branch. Don't try to import both at once — only one is in the package graph per build.
- **`Window.position()` / `setPosition` / `.didMove` are no-ops on the GTK4 backend.** GTK4 dropped the position API; Wayland refuses to give apps their own position. The cross-platform `Window` protocol documents this as best-effort.
- The GTK3 C shim assumes the **WebKitGTK 4.1 ABI** specifically — `WebKitJavascriptResult` is a boxed type (not a GObject) on the script-message callback. The GTK4 shim handles the 6.0 ABI where the same callback receives a `JSCValue*` directly.
- **`webView.evaluateJavaScript(_:)` bridges the `GAsyncResult` callback chain back into a Swift `CheckedContinuation`** via the `swiftpwa_evaluate_javascript` shim. The result string is the JSON serialization of the JS value (or `nil` for `undefined`). Errors are surfaced as `BridgeError(code: E_HANDLER)`.
- `GtkWidget*` is laundered through `UInt` for strict-concurrency compliance (see commit 3da4f03).

## Conventions

- `swift-tools-version:6.0` enables strict concurrency by default. **Do not** add `enableUpcomingFeature("StrictConcurrency")` — under Swift 6 on Linux it is treated as an error rather than a warning. Only `ExistentialAny` is opted in. See the comment block at the top of [Package.swift](Package.swift).
- swiftformat config: 4-space indent, 120 max width, `--self remove`, `--stripunusedargs closure-only`. Examples are excluded.
- Tests use **swift-testing** (`@Test`, `#expect`), not XCTest.
- **Cross-platform parity is the default.** If a feature lands on one backend (Apple `SwiftPWAWebKit` or Linux `SwiftPWAGTK`), implement the equivalent on the others in the same change — adapted to each platform's HIG / norms rather than ported literally. Example: Mac's Cmd+Q lives in an `NSApplication` menu; the Linux equivalent is a `GtkAccelGroup` Ctrl+Q binding plus quit-on-last-window-closed (Mac keeps the menu bar after last window; Linux exits). If parity isn't feasible in the same change, document it in [docs/linux-setup.md](docs/linux-setup.md)'s "Known limitations" section (or the equivalent platform doc) so users aren't surprised.
