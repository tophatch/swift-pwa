# Changelog

All notable changes to swift-pwa will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Platform-agnostic `SwiftPWACore`: `CommandRegistry`, `Invocation` envelope, `Window` / `PWAWebView` / `AppRuntime` protocols, `Plugin` model, built-in `WindowPlugin` exposing the `window.*` JS command set.
- Apple `SwiftPWAWebKit` backend (macOS 15+, iOS 18+) with `WKWebView`, `pwa://` scheme handler, UIScene multi-window scaffolding. JS↔Swift bridge round-trip verified end-to-end on the iOS 26 Simulator.
- Linux `SwiftPWAGTK` backend (GTK3 + WebKitGTK 4.1) via hand-rolled C shims (`CGtk3Shim`, `CWebKitGTK4Shim`). JS↔Swift bridge round-trip verified end-to-end on Ubuntu 24.04.
- `MainThread.run` abstraction in core: routes "run on UI thread" through a registerable platform hook (`DispatchQueue.main` on Apple, `g_idle_add` on GTK) so the bridge runtime works under `gtk_main()`, where Swift's MainActor executor is otherwise un-pumped.
- `swift-pwa` CLI: `init`, `dev`, `build` for macOS `.app` (with optional `--sign`), iOS `.ipa` / simulator `.app` (via `xcodebuild`), Linux `.AppImage` (via `linuxdeploy`). Windows / Android targets are stubs.
- AppImage bundler: writes a placeholder PNG icon if `pwa.json.icon` isn't a PNG so `linuxdeploy` doesn't hang on its prompt path.
- `__SWIFT_PWA__.invoke()` / `subscribe()` JS runtime injected at document start; uniform Tauri-style envelope (`{v, kind, id, cmd, payload}`).
- Test support target (`_SwiftPWATestSupport`) with reusable `MockWindow` / `MockWebView` / `MockAppContext`.
- 34-test suite (Swift Testing): envelope codec, `JSONValue`, `CommandRegistry`, `AssetProvider`, `WindowPlugin`, `BridgeRuntime` end-to-end, real-`WKWebView` integration, `PWAManifest`, `InfoPlist`.
- GitHub Actions CI matrix: macos-15 (build + test + WKWebView integration), ios-build (xcodebuild against the iOS Simulator SDK), ubuntu-24.04 (Core + CLI), swiftformat lint. Tag-driven release workflow that ships CLI binaries.
- [docs/linux-setup.md](docs/linux-setup.md) walkthrough for Ubuntu 24.04.

### Fixed

- Linux `evaluateJavaScript` is no longer fire-and-forget. The GTK adapter now bridges `webkit_web_view_evaluate_javascript`'s `GAsyncResult` callback back into a Swift `CheckedContinuation` via the new `swiftpwa_evaluate_javascript` shim. The result is the JSON serialization of the JS value (`jsc_value_to_json`) — `undefined` resolves to `nil`, and WebKit-side errors throw `BridgeError(code: E_HANDLER)`.
- iOS bundler now assembles the `.app` itself from xcodebuild's loose products. SwiftPM executable targets compile to a bare Mach-O, not a bundle, so the previous code never found the `.app` it was looking for and failed every build with `expected built binary at …`.
- iOS `Info.plist` no longer ships `$(PRODUCT_MODULE_NAME).SwiftPWASceneDelegate` as a literal string (Xcode-only build-setting variable); resolved to `SwiftPWAWebKit.SwiftPWASceneDelegate`.
- iOS `Info.plist` now declares `UILaunchScreen` so the app doesn't run in legacy compatibility letterbox mode on modern devices.
- `swift-pwa init` scaffolds `Sources/<Name>/App.swift` instead of `main.swift`, so the templated `@main` struct compiles (the `main.swift` filename forces top-level-script mode).

### Notes

- `CommandRegistry` is a class with `NSLock`-guarded state, not an actor. Registration is synchronous so user `configure` closures can run on a thread that isn't pumping Swift's MainActor executor (e.g. the main thread before `gtk_main()` enters its loop).
- `BridgeRuntime` is *not* `@MainActor`. Backends are responsible for hopping to the platform UI thread internally.
