# Changelog

All notable changes to swift-pwa will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Notifications plugin.** New opt-in `NotificationsPlugin` exposes `notifications.requestAuthorization` and `notifications.send({title, body?, sound?})`. Apple uses `UNUserNotificationCenter` (works in a bundled, signed `.app`; `swift run` returns "not allowed" since the process has no bundle identity, surfaced as a thrown `BridgeError(code: .handler)`). Linux hits `org.freedesktop.Notifications` directly through GIO's `g_dbus_connection_call_sync` — no libnotify / libayatana-appindicator dep, just a new `gio-2.0` link in the C shim modulemaps (already supplied by `libglib2.0-dev`). Click events / actions / replace-by-id are intentionally deferred — they need delegate / signal plumbing that's better landed alongside a `notifications.subscribe` stream.
- `_SwiftPWATestSupport.MockNotifications` for plugin-level unit tests.
- **Tray plugin.** New opt-in `TrayPlugin` exposes `tray.setIcon`, `tray.setTooltip`, `tray.setMenu`, `tray.setVisible`, and `tray.subscribe` (streaming `.click` / `.menuItemClicked` events). Full implementation on macOS via `NSStatusItem` + `NSMenu`, and on the GTK3 Linux backend via `GtkStatusIcon` + `GtkMenu` (entire state machine encapsulated in the `swiftpwa_tray_*` C shim with `-Wdeprecated-declarations` localised there, so the GtkStatusIcon deprecation stays out of Swift). On iOS and the GTK4 backend `SystemTray()` returns a no-op stub that logs a one-shot warning — iOS has no system tray and GTK4 removed `GtkStatusIcon`; AppIndicator support is on the v0.3 roadmap. `TrayEvent` uses the same `{type: "...", ...}` JSON discriminator as `WindowEvent`.
- `_SwiftPWATestSupport.MockTray` for plugin-level unit tests.
- **Clipboard plugin.** `ClipboardPlugin` is now auto-installed on every backend's `AppContext` alongside `WindowPlugin`, exposing `clipboard.readText`, `clipboard.writeText`, and `clipboard.clear` to JS. Backends provide a `SystemClipboard`: `NSPasteboard.general` on macOS, `UIPasteboard.general` on iOS, `GtkClipboard` on the GTK3 backend, and `GdkClipboard` on the GTK4 backend — the GTK4 implementation bridges `gdk_clipboard_read_text_async` into a Swift `CheckedContinuation` through a new `swiftpwa_clipboard_*` shim so the `Clipboard` protocol stays uniform across backends. `clear()` semantics differ by platform (Apple wipes the system clipboard; X11 / Wayland only relinquish local ownership) — documented on the protocol.
- `_SwiftPWATestSupport.MockClipboard` for plugin-level unit tests.

## [0.1.0] - 2026-05-04

### Added

- Platform-agnostic `SwiftPWACore`: `CommandRegistry`, `Invocation` envelope, `Window` / `PWAWebView` / `AppRuntime` protocols, `Plugin` model, built-in `WindowPlugin` exposing the `window.*` JS command set.
- Apple `SwiftPWAWebKit` backend (macOS 15+, iOS 18+) with `WKWebView`, `pwa://` scheme handler, UIScene multi-window scaffolding. JS↔Swift bridge round-trip verified end-to-end on the iOS 26 Simulator.
- Linux `SwiftPWAGTK` backend, two parallel implementations selected at build time via the `SWIFT_PWA_GTK4` environment variable: GTK3 + WebKitGTK 4.1 (default, `CGtk3Shim` + `CWebKitGTK4Shim`) for older distros, and GTK4 + WebKitGTK 6.0 (`CGtk4Shim` + `CWebKitGTK6Shim`) for modern ones. Both export the same `SwiftPWAGTK` Swift module name and class API; the GTK4 backend uses `GtkShortcutController` for Ctrl+Q and `notify::default-width/-height` for resize tracking, since `GtkAccelGroup` and `configure-event` were removed in GTK4. Position APIs (`Window.position()` / `setPosition` / `.didMove`) are no-ops on GTK4 because Wayland and CSD removed the concept; the protocol now documents this as best-effort.
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
- Linux backend now emits `WindowEvent.didResize` / `.didMove` for user-driven window-manager resizes and moves (hooked via GTK `configure-event`), matching the Mac `NSWindowDelegate` plumbing.
- Linux backend now wires Ctrl+Q (the GNOME HIG quit shortcut) to `GTKAppContext.quit` via a window-level `GtkAccelGroup`, hooks `delete-event` so user-clicked [X] / Alt+F4 runs the same teardown as a programmatic `close()`, and quits the GLib main loop when the last window closes — Linux convention vs Mac's "menu bar lingers". The Ctrl+Q wiring matches the existing macOS Cmd+Q path installed by the app menu.
- iOS bundler now assembles the `.app` itself from xcodebuild's loose products. SwiftPM executable targets compile to a bare Mach-O, not a bundle, so the previous code never found the `.app` it was looking for and failed every build with `expected built binary at …`.
- iOS `Info.plist` no longer ships `$(PRODUCT_MODULE_NAME).SwiftPWASceneDelegate` as a literal string (Xcode-only build-setting variable); resolved to `SwiftPWAWebKit.SwiftPWASceneDelegate`.
- iOS `Info.plist` now declares `UILaunchScreen` so the app doesn't run in legacy compatibility letterbox mode on modern devices.
- `swift-pwa init` scaffolds `Sources/<Name>/App.swift` instead of `main.swift`, so the templated `@main` struct compiles (the `main.swift` filename forces top-level-script mode).

### Notes

- `CommandRegistry` is a class with `NSLock`-guarded state, not an actor. Registration is synchronous so user `configure` closures can run on a thread that isn't pumping Swift's MainActor executor (e.g. the main thread before `gtk_main()` enters its loop).
- `BridgeRuntime` is *not* `@MainActor`. Backends are responsible for hopping to the platform UI thread internally.
